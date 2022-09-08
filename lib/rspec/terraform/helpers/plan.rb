# frozen_string_literal: true

require 'ruby_terraform'
require 'securerandom'
require 'stringio'

require_relative '../configuration/var_captor'

module RSpec
  module Terraform
    module Helpers
      # rubocop:disable Metrics/ClassLength
      class Plan
        attr_reader(
          :configuration_provider,
          :binary,
          :logger,
          :stdin,
          :stdout,
          :stderr,
          :execution_mode
        )

        def initialize(opts = {})
          @configuration_provider =
            opts[:configuration_provider] || Configuration.identity_provider
          @binary = opts[:binary] || 'terraform'
          @logger = opts[:logger]
          @stdin = opts[:stdin]
          @stdout = opts[:stdout]
          @stderr = opts[:stderr]
          @execution_mode = opts[:execution_mode] || :in_place
        end

        def execute(overrides = {}, &block)
          parameters = with_configuration_provider_parameters(overrides)
          parameters = with_resolved_vars(parameters, &block)

          ensure_required_parameters(parameters)

          clean(parameters)
          init(parameters)
          plan_file = plan(parameters)
          plan_contents = show(parameters, plan_file)
          remove(parameters, plan_file)
          parse(plan_contents)
        end

        private

        def with_configuration_provider_parameters(parameters)
          configuration_provider.resolve(parameters)
        end

        def with_resolved_vars(parameters, &block)
          return parameters unless block_given?

          var_captor = Configuration::VarCaptor.new(parameters[:vars] || {})
          block.call(var_captor)
          parameters.merge(vars: var_captor.to_h)
        end

        def required_parameters(execution_mode)
          {
            in_place: [:configuration_directory],
            isolated: %i[source_directory configuration_directory]
          }[execution_mode] || []
        end

        def ensure_required_parameters(parameters)
          missing_parameters =
            required_parameters(execution_mode)
              .filter { |parameter| parameters[parameter].nil? }

          return if missing_parameters.empty?

          raise_missing_parameters(missing_parameters)
        end

        def raise_missing_parameters(parameters)
          parameters = parameters.collect { |parameter| "`:#{parameter}`" }
          if parameters.count == 1
            raise StandardError,
                  "Required parameter: #{parameters[0]} missing."
          else
            parameters = "#{parameters[..-2].join(', ')} and #{parameters[-1]}"
            raise StandardError,
                  "Required parameters: #{parameters} missing."
          end
        end

        def clean(parameters)
          return unless execution_mode == :isolated

          FileUtils.rm_rf(parameters[:configuration_directory])
          FileUtils.mkdir_p(parameters[:configuration_directory])
        end

        def init(parameters)
          init_command.execute(init_parameters(parameters))
        end

        def plan(parameters)
          plan_parameters = plan_parameters(parameters)
          plan_command.execute(plan_parameters)
          plan_parameters[:out]
        end

        def show(parameters, plan_file)
          stdout = StringIO.new
          show_command(stdout: stdout)
            .execute(show_parameters(parameters, plan_file))
          stdout.string
        end

        def parse(plan_contents)
          RubyTerraform::Models::Plan.new(
            JSON.parse(plan_contents, symbolize_names: true)
          )
        end

        def remove(parameters, plan_file)
          FileUtils.rm_f(
            File.join(parameters[:configuration_directory], plan_file)
          )
        end

        def init_command
          RubyTerraform::Commands::Init.new(command_options)
        end

        def plan_command
          RubyTerraform::Commands::Plan.new(command_options)
        end

        def show_command(opts = {})
          RubyTerraform::Commands::Show.new(command_options.merge(opts))
        end

        def init_parameters(parameters)
          init_parameters = parameters.merge(
            chdir: parameters[:configuration_directory],
            input: false
          )
          if execution_mode == :isolated
            init_parameters =
              init_parameters.merge(from_module: parameters[:source_directory])
          end

          init_parameters
        end

        # rubocop:disable Metrics/MethodLength
        def plan_parameters(parameters)
          plan_parameters =
            parameters.merge(
              chdir: parameters[:configuration_directory],
              out: parameters[:plan_file_name] ||
                "#{SecureRandom.hex[0, 10]}.tfplan",
              input: false
            )

          if parameters[:state_file]
            plan_parameters =
              plan_parameters.merge(state: parameters[:state_file])
          end

          plan_parameters
        end
        # rubocop:enable Metrics/MethodLength

        def show_parameters(parameters, plan_file)
          parameters.merge(
            chdir: parameters[:configuration_directory],
            path: plan_file,
            no_color: true,
            json: true
          )
        end

        def command_options
          {
            binary: binary,
            logger: logger,
            stdin: stdin,
            stdout: stdout,
            stderr: stderr
          }
        end
      end
      # rubocop:enable Metrics/ClassLength
    end
  end
end
