require 'yu/version'
require 'commander'

module Yu
  class CLI
    include Commander::Methods

    def self.call(*args)
      new(*args).call
    end

    def call
      program :name, 'yu'
      program :version, VERSION
      program :description, 'Helps you manage your microservices'

      command :test do |c|
        c.syntax = 'yu test'
        c.description = 'Run tests for service(s)'
        c.action(method(:test))
      end

      command :build do |c|
        c.syntax = 'yu build'
        c.description = 'Build image for service(s)'
        c.action(method(:build))
      end

      command :shell do |c|
        c.syntax = 'yu shell'
        c.description = 'Start a shell container for a service'
        c.option '--test'
        c.action(method(:shell))
      end

      command :reset do |c|
        c.syntax = 'yu reset'
        c.description = 'Reset everything'
        c.action(method(:reset))
      end

      command :doctor do |c|
        c.syntax = 'yu doctor'
        c.description = 'Check your environment is ready to yu'
        c.action(method(:doctor))
      end

      global_option('-V', '--verbose', 'Verbose output') { $verbose_mode = true }

      run!
    end

    private

    def test(args, options)
      if args.none?
        target_containers = testable_containers
      else
        target_containers = args.map(&method(:normalise_container_name_from_dir))
      end

      results = target_containers.map do |container|
        info "Running tests for #{container}..."
        run_command(
          "docker-compose run --rm #{container} bin/test",
          exit_on_failure: false,
        )
      end

      exit 1 unless results.all?(&:success?)
    end

    def build(args, options)
      target_containers = args.map(&method(:normalise_container_name_from_dir))
      if target_containers.none?
        target_gemfiled_containers = gemfiled_containers
      else
        target_gemfiled_containers = gemfiled_containers & target_containers
      end

      target_gemfiled_containers.each(&method(:package_gems_for_container))
      info "Building images..."
      execute_command("docker-compose build #{target_containers.join(" ")}")
    end

    def shell(args, options)
      case args.count
      when 0
        info "Please provide container"
        exit 1
      when 1
        target_container = normalise_container_name_from_dir(args.first)
        env_option = options.test ? "-e APP_ENV=test" : ""
        info "Loading #{"test" if options.test} shell for #{target_container}..."
        execute_command("docker-compose run --rm #{env_option} #{target_container} bash")
      else
        info "One at a time please!"
        exit 1
      end
    end

    def reset(args, options)
      info "Packaging gems in all services containing a Gemfile"
      gemfiled_containers.each(&method(:package_gems_for_container))
      info "Killing any running containers"
      run_command("docker-compose kill")
      info "Removing all existing containers"
      run_command "docker-compose rm --force"
      info "Building fresh images"
      run_command "docker-compose build"
      if File.exists? 'seed'
        info "Seeding system state"
        run_command "./seed"
      end
      info "Bringing all containers up"
      run_command "docker-compose up -d --no-recreate"
    end

    def doctor(args, options)
      run_command "docker", showing_output: false do
        info "Please ensure you have docker working"
        exit 1
      end
      run_command "docker-compose --version", showing_output: false do
        info "Please ensure you have docker-compose working"
        exit 1
      end
      run_command "docker-compose ps", showing_output: false do
        info "Your current directory does not contain a docker-compose.yml"
        exit 1
      end
      info "Everything looks good."
    end

    def run_command(command, showing_output: true, exit_on_failure: true)
      unless showing_output || verbose_mode?
        command = "#{command} &>/dev/null"
      end

      pid = fork { execute_command(command) }
      _, process = Process.waitpid2(pid)

      process.tap do |result|
        unless result.success?
          if block_given?
            yield
          else
            if exit_on_failure
              info "Command failed: #{command}"
              info "Exiting..."
              exit 1
            end
          end
        end
      end
    end

    def package_gems_for_container(container)
      info "Packaging gems for #{container}"
      run_command("cd #{container} && bundle package --all")
    end

    def gemfiled_containers
      containers_with_file("Gemfile")
    end

    def testable_containers
      containers_with_file("bin/test")
    end

    def normalise_container_name_from_dir(container_name_or_dir)
      File.basename(container_name_or_dir)
    end

    def containers_with_file(file)
      Dir.glob("*/#{file}").map { |dir_path| dir_path.split("/").first }
    end

    def execute_command(command)
      info "Executing: #{command}" if verbose_mode?
      exec(command)
    end

    def info(message)
      say "[yu] #{message}"
    end

    def verbose_mode?
      !!$verbose_mode
    end
  end
end
