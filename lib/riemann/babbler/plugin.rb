#encoding: utf-8

# Базовое описание плагина
module Riemann
  module Babbler

    require 'riemann/client'
    require 'open3'
    require 'timeout'
    require 'rest_client'

    def self.included(base)
      base.instance_eval do
        def run
          new.run
        end
      end
    end

    def initialize
      @configatron = $configatron
      @storage = Hash.new
      init
      run
    end

    def log
      @logger ||= $logger
    end

    def options
      @configatron
    end
    alias :opts :options

    def report(event)
      case event[:metric]
        when Hash
          report_with_diff(event) and return
      end
      event[:tags] = options.riemann.tags unless options.riemann.tags.nil?
      event[:host] =  host
      log.debug "Report status: #{event.inspect}"
      riemann << event
    end

    def report_with_diff(event)
      current_metric = event[:metric][:value]
      event[:metric][:value] = current_metric - @storage[ event[:service] ] if @storage.has_key? event[:service]
      @storage[ event[:service] ] = current_metric
      event[:state] = state(current_metric) unless plugin.states.critical.nil?
      event[:metric] = event[:metric][:value]
      report(event)
    end

    def host
      hostname = `hostname`.chomp.downcase
      hostname += options.riemann.suffix unless options.riemann.suffix.nil?
      hostname = options.riemann.prefix + hostname unless options.riemann.prefix.nil?
      hostname
    end

    # не запускаем плагин есть 
    def run_plugin
      true
    end

    # http rest 
    def rest_get(url)
      begin
        RestClient.get url
      rescue
        report({
          :service => plugin.service,
          :state => 'critical',
          :description => "Response from #{url}"
        })
      end
    end

    def riemann
      @riemann ||= Riemann::Client.new(
        :host => options.riemann.host,
        :port => options.riemann.port
      )
    end
    alias :r :riemann

    def run
      # выйти если run_plugin не равен true
      return 0 unless run_plugin == true
      t0 = Time.now
      loop do
        begin
          tick
        rescue => e
          #report({:service => plugin.service, :status => 'critical'})
          $stderr.puts "#{e.class} #{e}\n#{e.backtrace.join "\n"}"
        end

        sleep(plugin.interval - ((Time.now - t0) % plugin.interval))
      end
    end

    # Переодически вызываемое действие
    def tick
      posted_hash = collect
      posted_hash.each_key do |service|
        case service
        when Hash
          report({
            :service => plugin.service + " " + service,
            :metric => posted_hash[service],
            :is_diff => posted_hash[:is_diff]
          })
        else
          report({
            :service => plugin.service + " " + service,
            :metric => posted_hash[service]           
            })
        end
      end
    end

    # Доступ к конфигу определенного плагина
    def plugin
      plugin_name = self.class.name.split( "::" ).last.gsub( /(\p{Lower})(\p{Upper})/, "\\1_\\2" ).downcase
      options.plugins.send plugin_name
    end

    # Plugin init
    def init
    end

    # хэлпер для парса stdout+stderr и exit status
    def shell(*cmd)
      exit_status=nil
      err=nil
      out=nil
      Timeout::timeout(5) {
        Open3.popen3(*cmd) do |stdin, stdout, stderr, wait_thread|
          err = stderr.gets(nil)
          out = stdout.gets(nil)
          [stdin, stdout, stderr].each{|stream| stream.send('close')}
          exit_status = wait_thread.value
        end
      }
      if exit_status.to_i > 0
        err = err.chomp if err
        raise err
      elsif out
        return out.chomp
      else
        return true
      end
    end

    # хелпер, описание статуса
    def state(my_state)
      unless plugin.states.warning.nil?
        case
        when my_state.between?(plugin.states.warning, plugin.states.critical)
          'warning'
        when my_state > plugin.states.warning
          'critical'
        else
          'ok'
        end
      else
        my_state >= plugin.states.critical ? 'critical' : 'ok'
      end
    end

  end
end
