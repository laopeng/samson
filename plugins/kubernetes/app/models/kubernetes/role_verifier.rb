# frozen_string_literal: true
module Kubernetes
  class RoleVerifier
    DEPLOYISH = RoleConfigFile::DEPLOY_KINDS
    JOBS = RoleConfigFile::JOB_KINDS
    CONTAINERED = DEPLOYISH + JOBS << 'Pod'
    VALID_LABEL = /\A[a-zA-Z0-9]([-a-zA-Z0-9]*[a-zA-Z0-9])?\z/ # also used in js ... cannot use /i

    SUPPORTED_KINDS = [
      ['Deployment'],
      ['DaemonSet'],
      ['Deployment', 'Service'],
      ['Job'],
      ['Pod'],
    ].freeze

    def initialize(elements)
      @errors = []
      @elements = elements.compact
    end

    def verify
      return @errors if @errors.any?
      return ["No content found"] if @elements.blank?
      return ["Only hashes supported"] unless @elements.all? { |e| e.is_a?(Hash) }
      verify_name
      verify_namespace
      verify_kinds
      verify_containers
      verify_container_name
      verify_job_restart_policy
      verify_numeric_limits
      verify_project_and_role_consistent
      verify_annotations
      verify_env_values
      @errors.presence
    end

    private

    def verify_name
      @errors << "Needs a metadata.name" unless map_attributes([:metadata, :name]).all?
    end

    def verify_namespace
      @errors << "Namespaces need to be unique" if map_attributes([:metadata, :namespace]).uniq.size != 1
    end

    def verify_kinds
      kinds = map_attributes([:kind]).sort_by(&:to_s)
      return if SUPPORTED_KINDS.include?(kinds - ['ConfigMap'])
      supported = SUPPORTED_KINDS.map { |c| c.join(' + ') }.join(', ')
      @errors << "Unsupported combination of kinds: #{kinds.join(' + ')}" \
        ", supported combinations are: #{supported} and ConfigMap"
    end

    # spec actually allows this, but blows up when used
    def verify_numeric_limits
      base = [:spec, :template, :spec, :containers, :resources, :limits, :cpu]
      types = map_attributes(base, array: :first).map(&:class)
      return if (types - [NilClass, String]).none?
      @errors << "Numeric cpu limits are not supported"
    end

    def verify_project_and_role_consistent
      labels = @elements.flat_map do |resource|
        kind = resource[:kind]

        label_paths =
          case kind
          when 'Service'
            [
              [:metadata, :labels],
              [:spec, :selector]
            ]
          when *DEPLOYISH
            [
              [:metadata, :labels],
              [:spec, :template, :metadata, :labels],
              [:spec, :selector, :matchLabels],
            ]
          when *JOBS
            [
              [:metadata, :labels],
              [:spec, :template, :metadata, :labels]
            ]
          else # when adding new keep consistent with error message below
            [] # ignore unknown / unsupported types
          end

        label_paths.map do |path|
          labels = path.inject(resource) { |r, k| r[k] || {} }

          # role and project from all used labels
          wanted = [:project, :role]
          required = labels.slice(*wanted)
          if required.size != 2
            @errors << "Missing #{wanted.join(' or ')} for #{kind} #{path.join('.')}"
          end

          # make sure we get sane values for labels or deploy will blow up
          labels.each do |k, v|
            if v.is_a?(String)
              @errors << "#{kind} #{path.join('.')}.#{k} must match #{VALID_LABEL.inspect}" unless v =~ VALID_LABEL
            else
              @errors << "#{kind} #{path.join('.')}.#{k} must be a String"
            end
          end

          required
        end
      end

      return if labels.uniq.size <= 1
      @errors << "Project and role labels must be consistent across Deployment/DaemonSet/Service/Job"
    end

    def verify_containers
      containered = templates.select { |t| CONTAINERED.include?(t[:kind]) }
      containers = map_attributes([:spec, :containers], elements: containered)
      return if containers.all? { |c| c.is_a?(Array) && c.size >= 1 }
      @errors << "#{CONTAINERED.join("/")} need at least 1 container"
    end

    def verify_container_name
      names = map_attributes([:spec, :containers], elements: templates).compact.flatten(1).map { |c| c[:name] }
      if names.any?(&:nil?)
        @errors << "Containers need a name"
      elsif bad = names.grep_v(VALID_LABEL).presence
        @errors << "Container name #{bad.join(", ")} did not match #{VALID_LABEL.source}"
      end
    end

    def verify_job_restart_policy
      allowed = ['Never', 'OnFailure']
      path = [:spec, :template, :spec, :restartPolicy]
      names = map_attributes(path, elements: jobs)
      return if names - allowed == []
      @errors << "Job #{path.join('.')} must be one of #{allowed.join('/')}"
    end

    def verify_annotations
      path = [:metadata, :annotations]
      annotations = map_attributes(path, elements: templates)
      @errors << "Annotations must be a hash" if annotations.any? { |a| a && !a.is_a?(Hash) }
    end

    def verify_env_values
      path = [:spec, :containers, :env, :value]
      values = map_attributes(path, array: :first, elements: templates).compact
      bad = values.reject { |x| x.is_a?(String) }
      @errors << "Env values #{bad.join(', ')} must be strings." if bad.any?
    end

    def jobs
      @elements.select { |e| JOBS.include?(e[:kind]) }
    end

    def templates
      @elements.map do |e|
        kind = e[:kind]
        if kind != 'Pod'
          e = e.dig(:spec, :template) || {}
          e[:kind] = kind
        end
        e
      end
    end

    def map_attributes(path, elements: @elements, array: :all)
      elements.map do |e|
        path.inject(e) do |el, p|
          el = el[p]
          el = Array.wrap(el).first if array == :first
          el || break
        end
      end
    end
  end
end
