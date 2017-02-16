require_relative "includes"
require_relative "../logging"
require_relative "keyring"
require_relative "../profile_configuration"
require_relative "../credentials/providers/mfa_session_credentials"

class AwsAssumeRole::Store::SharedConfigWithKeyring < AwsAssumeRole::Vendored::Aws::SharedConfig
    include AwsAssumeRole::Store
    include AwsAssumeRole::Logging

    attr_reader :parsed_config

    def initialize(options = {})
        super(options)
        @config_enabled = true
        @config_path = determine_config_path
        load_config_file
    end

    def credentials(opts = {})
        p = opts[:profile] || @profile_name
        validate_profile_exists(p) if credentials_present?
        credentials_from_keyring(p, opts) || credentials_from_shared(p, opts) || credentials_from_config(p, opts)
    end

    def save_profile(profile_name, hash)
        ckey = "profile #{profile_name}"
        merged_config = configuration[ckey].deep_symbolize_keys.merge hash.to_h
        merged_config[:mfa_serial] = merged_config[:serial_number] if merged_config[:serial_number]
        credentials = Aws::Credentials.new(merged_config.delete(:aws_access_key_id),
                                           merged_config.delete(:aws_secret_access_key))
        semaphore.synchronize do
            Keyring.save_credentials profile_name, credentials if credentials.set?
            merged_config = merged_config.slice :region, :role_arn, :mfa_serial, :source_profile,
                                                :role_session_name, :external_id, :duration_seconds
            configuration.delete_section ckey
            configuration[ckey] = merged_config.compact
            save_configuration
        end
    end

    def profiles
        configuration.sections.map { |c| c.gsub("profile ", "") }
    end

    def delete_profile(profile_name)
        # Keyring does not return errors for non-existent things, so always attempt.
        Keyring.delete_credentials(profile_name)
        semaphore.synchronize do
            raise KeyError if configuration["profile #{profile_name}"].blank?
            configuration.delete_section("profile #{profile_name}")
            save_configuration
        end
    end

    def migrate_profile(profile_name)
        validate_profile_exists(profile_name)
        save_profile(profile_name, configuration["profile #{profile_name}"])
    end

    def profile_region(profile_name)
        prof_cfg = @parsed_config[profile_key(profile_name)]
        resolve_region(@parsed_config, prof_cfg)
    end

    def profile_role(profile_name)
        prof_cfg = @parsed_config[profile_key(profile_name)]
        resolve_arn(@parsed_config, prof_cfg)
    end

    def determine_profile(options)
        ret = options[:profile_name]
        ret ||= ENV["AWS_PROFILE"]
        ret ||= "default"
        ret
    end

    private

    def profile_key(profile)
        logger.debug "About to lookup #{profile}"
        if profile == "default" || profile.nil? || profile == ""
            "default"
        else
            profile
        end
    end

    def resolve_region(cfg, prof_cfg)
        return unless prof_cfg && cfg
        return prof_cfg["region"] if prof_cfg.key? "region"
        source_cfg = cfg[prof_cfg["source_profile"]]
        cfg[prof_cfg["source_profile"]]["region"] if source_cfg && source_cfg.key?("region")
    end

    def resolve_arn(cfg, prof_cfg)
        return unless prof_cfg && cfg
        return prof_cfg["role_arn"] if prof_cfg.key? "role_arn"
        source_cfg = cfg[prof_cfg["source_profile"]]
        cfg[prof_cfg["source_profile"]]["role_arn"] if source_cfg && source_cfg.key?("role_arn")
    end

    def assume_role_from_profile(cfg, profile, opts)
        prof_cfg = cfg[profile]
        return unless cfg && prof_cfg
        opts[:source_profile] ||= prof_cfg["source_profile"]
        if opts[:source_profile]
            opts[:credentials] = credentials(profile: opts[:source_profile])
            if opts[:credentials]
                opts[:role_session_name] ||= prof_cfg["role_session_name"]
                opts[:role_session_name] ||= "default_session"
                opts[:role_arn] ||= prof_cfg["role_arn"]
                opts[:external_id] ||= prof_cfg["external_id"]
                opts[:serial_number] ||= prof_cfg["mfa_serial"]
                opts[:region] ||= profile_region(profile)
                if opts[:serial_number]
                    mfa_opts = { credentials: opts[:credentials], region: opts[:region], serial_number: opts[:serial_number] }
                    mfa_creds = mfa_session(cfg, opts[:source_profile], mfa_opts)
                    opts.delete :serial_number
                end
                opts[:credentials] = mfa_creds if mfa_creds
                opts[:profile] = opts.delete(:source_profile)
                AwsAssumeRole::Credentials::Providers::AssumeRoleCredentials.new(opts)
            else
                raise ::Aws::Errors::NoSourceProfileError, "Profile #{profile} has a role_arn, and source_profile, but the"\
                      " source_profile does not have credentials."
            end
        elsif prof_cfg["role_arn"]
            raise ::Aws::Errors::NoSourceProfileError, "Profile #{profile} has a role_arn, but no source_profile."
        end
    end

    def mfa_session(cfg, profile, opts)
        prof_cfg = cfg[profile]
        return unless cfg && prof_cfg
        opts[:serial_number] ||= prof_cfg["mfa_serial"]
        opts[:source_profile] ||= prof_cfg["source_profile"]
        opts[:region] ||= profile_region(profile)
        return unless opts[:serial_number]
        opts[:credentials] ||= credentials(profile: opts[:profile])
        AwsAssumeRole::Credentials::Providers::MfaSessionCredentials.new(opts)
    end

    def credentials_from_keyring(profile, _options)
        return unless @parsed_config && @parsed_config[profile_key(profile)]
        logger.debug "Attempt to fetch #{profile} from keyring"
        creds = Serialization.credentials_from_hash Keyring.fetch(profile)
        creds if credentials_complete(creds)
    end

    def semaphore
        @semaphore ||= Mutex.new
    end

    def configuration
        @configuration ||= IniFile.new(filename: determine_config_path, default: "default")
    end

    # Please run in a mutex
    def save_configuration
        bytes_required = File.size(determine_config_path)
        random_bytes = SecureRandom.random_bytes(bytes_required)
        File.write(determine_config_path, random_bytes)
        configuration.save
    end
end

module AwsAssumeRole
    module_function

    def shared_config
        enabled = ENV["AWS_SDK_CONFIG_OPT_OUT"] ? false : true
        @assuome_role_shared_config ||= ::AwsAssumeRole::Store::SharedConfigWithKeyring.new(config_enabled: enabled)
    end
end