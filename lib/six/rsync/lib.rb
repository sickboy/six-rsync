module Six
  module Repositories
    module Rsync
      class RsyncExecuteError < StandardError
      end

      class Lib
        PROTECTED = false
        tmp = Hash.new
        tmp[:hosts] = []
        DEFAULT = tmp.to_yaml
        PARAMS = if PROTECTED
          "--dry-run --times -O --no-whole-file -r --delete --stats --progress --exclude=.rsync"
        else
          "--times -O --no-whole-file -r --delete --stats --progress --exclude=.rsync"
        end
        WINDRIVE = / (\w)\:/

        def initialize(base = nil, logger = nil)
          @rsync_dir = nil
          @rsync_work_dir = nil
          @path = nil

          if base.is_a?(Rsync::Base)
            @rsync_dir = base.repo.path
            @rsync_work_dir = base.dir.path if base.dir
          elsif base.is_a?(Hash)
            @rsync_dir = base[:repository]
            @rsync_work_dir = base[:working_directory]
          end
          @logger = logger
        end

        def init
          p rsync_path
          if FileTest.exist? rsync_path
            @logger.error "Seems to already be an Rsync repository, Aborting!"
            raise RsyncExecuteError
            #return
          end
          if FileTest.exist? @rsync_work_dir
            @logger.error "Seems to already be a folder, Aborting!"
            raise RsyncExecuteError
            #return
          end
          FileUtils.mkdir_p rsync_path
          write_config(config)
        end

        def config
          @config ||= YAML::load(DEFAULT)
        end

        def clone(repository, name, opts = {})
          @path = opts[:path] || '.'
          @rsync_work_dir = opts[:path] ? File.join(@path, name) : name
          if opts[:log]
            @logger = opts[:log]
          end

          case repository
          when Array
            config[:hosts] += repository
          when String
            config[:hosts] << repository
          end

          begin
            init

            # TODO: Eval move to update?
            arr_opts = []
            arr_opts << "-I" if opts[:force]

            begin
              update('', arr_opts)
            rescue
              @logger.error "Unable to sucessfully update, aborting..."
              # Dangerous? :D
              FileUtils.rm_rf @rsync_work_dir
            end
          rescue
            @logger.error "Unable to initialize"
          end

          opts[:bare] ? {:repository => @rsync_work_dir} : {:working_directory => @rsync_work_dir}
        end

        def update(cmd, x_opts = [])
          @config = read_config
          unless @config
            @logger.error "Not an Rsync repository!"
            return
          end

          p config
          unless config[:hosts].size > 0
            @logger.error "No hosts configured!"
            return
          end

          write_sums
          # fetch latest sums
          compare_sums
          # only update whne sums mismatch
          return

          arr_opts = []
          arr_opts << PARAMS
          arr_opts += x_opts
          arr_opts << config[:hosts].sample
          arr_opts << @rsync_work_dir

          command(cmd, arr_opts)
        end

        private
        def rsync_path
          File.join(@rsync_work_dir, '.rsync')
        end

        def read_config
          read_yaml(File.join(rsync_path, 'config.yml'))
        end

        def read_sums
          read_yaml(File.join(rsync_path, 'sums.yml'))
        end

        def read_yaml(file)
          if FileTest.exist?(file)
            YAML::load_file(file)
          else
            nil
          end          
        end

        def write_default_config
          FileUtils.mkdir_p rsync_path
          write_config(config)
        end

        def write_sums
          sums_pack = Hash.new
          sums_wd = Hash.new
          pack = /\A.pack[\\|\/]/
          Dir[File.join(@rsync_work_dir, '**/*')].each do |file|
            relative = file.gsub(/#{@rsync_work_dir}[\\|\/]/, '')
            sum = md5(file)
            sums_wd[relative] = sum if sum
          end
          File.open(File.join(@rsync_dir, 'sums_wd.yml'), 'w') { |file| file.puts sums_wd.sort.to_yaml }

          Dir[File.join(@rsync_work_dir, '.pack/**/*')].each do |file|
            relative = file.gsub(/#{@rsync_work_dir}[\\|\/]\.pack[\\|\/]/, '')
            rel = relative.gsub(pack, '')
            sum = md5(file)
            sums_pack[rel] = sum if sum
          end
          File.open(File.join(@rsync_dir, 'sums_pack.yml'), 'w') { |file| file.puts sums_pack.sort.to_yaml }
          File.open(File.join(@rsync_work_dir, '.pack', '.sums.yml'), 'w') {|file| file.puts sums_pack.sort.to_yaml }
          File.open(File.join(@rsync_work_dir, '.sums.yml'), 'w') {|file| file.puts sums_wd.sort.to_yaml }
        end

        def compare_sums
          local, remote = Hash.new, Hash.new

          File.open(File.join(@rsync_dir, 'sums_pack.yml')) do |file|
            local[:pack] = YAML::load(file)
            local[:pack_md5] = md5(file.path)
          end

          File.open(File.join(@rsync_dir, 'sums_wd.yml')) do |file|
            local[:wd] = YAML::load(file)
            local[:wd_md5] = md5(file.path)
          end

          File.open(File.join(@rsync_work_dir, '.pack', '.sums.yml')) do |file|
            remote[:pack] = YAML::load(file)
            remote[:pack_md5] = md5(file.path)
          end

          File.open(File.join(@rsync_work_dir, '.sums.yml')) do |file|
            remote[:wd] = YAML::load(file)
            remote[:wd_md5] = md5(file.path)
          end

          if local[:wd_md5] == remote[:wd_md5]
            puts "WD Match!"
          else
            puts "WD NOT match!"
            local[:wd].each_pair do |key, value|
              if value == remote[:wd][key]
                puts "Match!"
              else
                puts "Mismatch!"
              end
            end
          end

          if local[:pack_md5] == remote[:pack_md5]
            puts "Pack Match!"
          else
            puts "Pack NOT match!"
            local[:pack].each_pair do |key, value|
              if value == remote[:pack][key]
                puts "Match!"
              else
                puts "Mismatch!"
              end
            end
          end

        end

        def md5(file)
          unless File.directory? file
            Digest::MD5.hexdigest(File.read(file))
          end
        end

        def write_config(config = YAML::load(DEFAULT))
          File.open(File.join(rsync_path, 'config.yml'), 'w') { |file| file.puts config.to_yaml }
        end

        def command_lines(cmd, opts = [], chdir = true, redirect = '')
          command(cmd, opts, chdir).split("\n")
        end

        def command(cmd, opts = [], chdir = true, redirect = '', &block)
          path = @rsync_work_dir || @rsync_dir || @path

          opts = [opts].flatten.map {|s| s }.join(' ') # escape()
          rsync_cmd = "rsync #{cmd} #{opts} #{redirect} 2>&1"
          while rsync_cmd[WINDRIVE] do
            drive = rsync_cmd[WINDRIVE]
            rsync_cmd.gsub!(drive, " /cygdrive/#{$1}")
          end

          out = nil
          if chdir && (Dir.getwd != path)
            Dir.chdir(path) { out = run_command(rsync_cmd, &block) }
          else
            out = run_command(rsync_cmd, &block)
          end

          if @logger
            @logger.info(rsync_cmd)
            @logger.debug(out)
          end

          if $?.exitstatus > 0
            if $?.exitstatus == 1 && out == ''
              return ''
            end
            raise Rsync::RsyncExecuteError.new(rsync_cmd + ':' + out.to_s)
          end
          out
        end

        def run_command(rsync_cmd, &block)
          if block_given?
            IO.popen(rsync_cmd, &block)
          else
            `#{rsync_cmd}`.chomp
          end
        end

        def escape(s)
          "\"" + s.to_s.gsub('\"', '\"\\\"\"') + "\""
        end
      end
    end
  end
end
