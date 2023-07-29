require "spec_helper"

require "tempfile"

describe "Invoker::Config" do
  describe "with invalid directory" do
    it "should raise error during startup" do
      begin
        file = Tempfile.new(["invalid_config", ".ini"])

        config_data =<<-EOD
[try_sleep]
directory = /Users/gnufied/foo
command = ruby try_sleep.rb
      EOD
        file.write(config_data)
        file.close
        expect {
          Invoker::Parsers::Config.new(file.path, 9000)
        }.to raise_error(Invoker::Errors::InvalidConfig)
      ensure
        file.unlink()
      end
    end
  end

  describe "with relative directory path" do
    it "should expand path in commands" do
      begin
        file = Tempfile.new(["config", ".ini"])

        config_data =<<-EOD
[pwd_home]
directory = ~
command = pwd

[pwd_parent]
directory = ../
command = pwd
      EOD
        file.write(config_data)
        file.close

        config = Invoker::Parsers::Config.new(file.path, 9000)
        command1 = config.processes.first

        expect(command1.dir).to match(File.expand_path('~'))

        command2 = config.processes[1]

        expect(command2.dir).to match(File.expand_path('..'))
      ensure
        file.unlink()
      end
    end
  end

  describe "for ports" do
    it "should replace port in commands" do
      begin
        file = Tempfile.new(["invalid_config", ".ini"])

        config_data =<<-EOD
[try_sleep]
directory = /tmp
command = ruby try_sleep.rb -p $PORT

[ls]
directory = /tmp
command = ls -p $PORT

[noport]
directory = /tmp
command = ls
      EOD
        file.write(config_data)
        file.close

        config = Invoker::Parsers::Config.new(file.path, 9000)
        command1 = config.processes.first

        expect(command1.port).to eq(9000)
        expect(command1.cmd).to match(/9000/)

        command2 = config.processes[1]

        expect(command2.port).to eq(9001)
        expect(command2.cmd).to match(/9001/)

        command2 = config.processes[2]

        expect(command2.port).to be_nil
      ensure
        file.unlink()
      end
    end

    it "should use port from separate option" do
      begin
        file = Tempfile.new(["invalid_config", ".ini"])
        config_data =<<-EOD
[try_sleep]
directory = /tmp
command = ruby try_sleep.rb -p $PORT

[ls]
directory = /tmp
port = 3000
command = pwd

[noport]
directory = /tmp
command = ls
      EOD
        file.write(config_data)
        file.close

        config = Invoker::Parsers::Config.new(file.path, 9000)
        command1 = config.processes.first

        expect(command1.port).to eq(9000)
        expect(command1.cmd).to match(/9000/)

        command2 = config.processes[1]

        expect(command2.port).to eq(3000)

        command2 = config.processes[2]

        expect(command2.port).to be_nil
      ensure
        file.unlink()
      end
    end
  end

  describe "loading power config", fakefs: true do
    before do
      FileUtils.mkdir_p('/tmp')
      FileUtils.mkdir_p(inv_conf_dir)
      File.open("/tmp/foo.ini", "w") { |fl| fl.write("") }
    end

    it "does not load config if platform is darwin but there is no power config file" do
      Invoker::Power::Config.expects(:load_config).never
      Invoker::Parsers::Config.new("/tmp/foo.ini", 9000)
    end

    it "loads config if platform is darwin and power config file exists" do
      File.open(Invoker::Power::Config.config_file, "w") { |fl| fl.puts "sample" }
      Invoker::Power::Config.expects(:load_config).once
      Invoker::Parsers::Config.new("/tmp/foo.ini", 9000)
    end
  end

  describe "Procfile" do
    it "should load Procfiles and create config object" do
      File.open("/tmp/Procfile", "w") {|fl|
        fl.write <<-EOD
web: bundle exec rails s -p $PORT
          EOD
      }
      config = Invoker::Parsers::Config.new("/tmp/Procfile", 9000)
      command1 = config.processes.first

      expect(command1.port).to eq(9000)
      expect(command1.cmd).to match(/bundle exec rails/)
    end
  end

  describe "Copy of DNS information" do
    it "should allow copy of DNS information" do
      File.open("/tmp/Procfile", "w") {|fl|
        fl.write <<-EOD
web: bundle exec rails s -p $PORT
          EOD
      }
      Invoker.load_config("/tmp/Procfile", 9000)
      dns_cache = Invoker::DNSCache.new(Invoker.config)

      expect(dns_cache.dns_data).to_not be_empty
      expect(dns_cache.dns_data['web']).to_not be_empty
      expect(dns_cache.dns_data['web']['port']).to eql 9000
    end
  end

  describe "#autorunnable_processes" do
    it "returns a list of processes that can be autorun" do
      begin
        file = Tempfile.new(["config", ".ini"])
        config_data =<<-EOD
[postgres]
command = postgres -D /usr/local/var/postgres

[redis]
command = redis-server /usr/local/etc/redis.conf
disable_autorun = true

[memcached]
command = /usr/local/opt/memcached/bin/memcached
disable_autorun = false

[panda-api]
command = bundle exec rails s
disable_autorun = true

[panda-auth]
command = bundle exec rails s -p $PORT
      EOD
        file.write(config_data)
        file.close

        config = Invoker::Parsers::Config.new(file.path, 9000)
        expect(config.autorunnable_processes.map(&:label)).to eq(['postgres', 'memcached', 'panda-auth'])
      ensure
        file.unlink()
      end
    end

    it "returns a list of processes that can by index" do
      begin
        file = Tempfile.new(["config", ".ini"])
        config_data =<<-EOD
[postgres]
command = postgres -D /usr/local/var/postgres
index = 2
sleep = 5

[redis]
command = redis-server /usr/local/etc/redis.conf
disable_autorun = true
index = 3

[memcached]
command = /usr/local/opt/memcached/bin/memcached
disable_autorun = false
index = 5

[panda-api]
command = bundle exec rails s
disable_autorun = true
index = 4

[panda-auth]
command = bundle exec rails s -p $PORT
index = 1
      EOD
        file.write(config_data)
        file.close

        config = Invoker::Parsers::Config.new(file.path, 9000)
        processes = config.autorunnable_processes
        expect(processes.map(&:label)).to eq(['panda-auth', 'postgres', 'memcached'])
        expect(processes[0].sleep_duration).to eq(0)
        expect(processes[1].sleep_duration).to eq(5)
      ensure
        file.unlink()
      end
    end
  end

  describe "global config file" do
    it "should use global config file if available" do
      begin
        FileUtils.mkdir_p(Invoker::Power::Config.config_dir)
        filename = "#{Invoker::Power::Config.config_dir}/foo.ini"
        file = File.open(filename, "w")
        config_data =<<-EOD
[try_sleep]
directory = /tmp
command = ruby try_sleep.rb
        EOD
        file.write(config_data)
        file.close
        config = Invoker::Parsers::Config.new("foo", 9000)
        expect(config.filename).to eql(filename)
      ensure
        File.unlink(filename)
      end
    end
  end

  describe "config file autodetection" do
    context "no config file given" do

      def create_invoker_ini
        file = File.open("invoker.ini", "w")
        config_data =<<-EOD
[some_process]
command = some_command
        EOD
        file.write(config_data)
        file.close

        file
      end

      def create_procfile
        file = File.open("Procfile", "w")
        config_data =<<-EOD
some_other_process: some_other_command
        EOD
        file.write(config_data)
        file.close

        file
      end

      context "directory has invoker.ini" do
        it "autodetects invoker.ini" do
          begin
            file = create_invoker_ini

            config = Invoker::Parsers::Config.new(nil, 9000)
            expect(config.process("some_process").cmd).to eq("some_command")
          ensure
            File.delete(file)
          end
        end
      end

      context "directory has Procfile" do
        it "autodetects Procfile" do
          begin
            file = create_procfile

            config = Invoker::Parsers::Config.new(nil, 9000)
            expect(config.process("some_other_process").cmd).to eq("some_other_command")
          ensure
            File.delete(file)
          end
        end
      end

      context "directory has both invoker.ini and Procfile" do
        it "prioritizes invoker.ini" do
          begin
            invoker_ini = create_invoker_ini
            procfile = create_procfile

            config = Invoker::Parsers::Config.new(nil, 9000)
            expect(config.process("some_process").cmd).to eq("some_command")
            processes = config.autorunnable_processes
            process_1 = processes[0]
            expect(process_1.sleep_duration).to eq(0)
            expect(process_1.index).to eq(0)
          ensure
            File.delete(invoker_ini)
            File.delete(procfile)
          end
        end
      end

      context "directory doesn't have invoker.ini or Procfile" do
        it "aborts" do
          expect { Invoker::Parsers::Config.new(nil, 9000) }.to raise_error(SystemExit)
        end
      end
    end
  end
end
