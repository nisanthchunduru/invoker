require "yaml"

module Invoker
  module Power
    # Save and Load Invoker::Power config
    class ConfigExists < StandardError; end

    class Config
      class << self
        def has_config?
          File.exist?(config_file)
        end

        def create(options = {})
          if has_config?
            raise ConfigExists, "Config file already exists at location #{config_file}"
          end
          config = new(options)
          config.save
        end

        def delete
          if File.exist?(config_file)
            File.delete(config_file)
          end
        end

        def load_config
          config_hash = File.open(config_file, "r") { |fl| YAML.load(fl) }
          new(config_hash)
        end

        def config_file
          File.join(Invoker.home, ".invoker", "config")
        end

        def config_dir
          File.join(Invoker.home, ".invoker")
        end
      end

      def initialize(options = {})
        @config = options
      end

      def dns_port=(dns_port)
        @config[:dns_port] = dns_port
      end

      def http_port=(http_port)
        @config[:http_port] = http_port
      end

      def https_port=(https_port)
        @config[:https_port] = https_port
      end

      def ipfw_rule_number=(ipfw_rule_number)
        @config[:ipfw_rule_number] = ipfw_rule_number
      end

      def dns_port; @config[:dns_port]; end
      def http_port; @config[:http_port]; end
      def ipfw_rule_number; @config[:ipfw_rule_number]; end
      def https_port; @config[:https_port]; end

      def tld
        @config[:tld] || Invoker.default_tld
      end

      def save
        File.open(self.class.config_file, "w") do |fl|
          YAML.dump(@config, fl)
        end
        self
      end
    end
  end
end
