module EtTools
  class NatMonitor
    require 'net/http'
    require 'net/ping'
    require 'fog'
    require 'yaml'
    require 'syslog'
    require 'dogapi'

    def initialize(conf_file = nil)
      @conf = defaults.merge load_conf(conf_file)
    end

    def load_conf(conf_file = nil)
      YAML.load_file(conf_file || '/etc/nat_monitor.yml')
    end

    def run
      validate!
      output 'Starting NAT Monitor'
      main_loop
    end

    def validate!
      case
      when !@conf['route_table_id']
        output 'route_table_id not specified'
        exit 1
      when !route_exists?(@conf['route_table_id'])
        output "Route #{@conf['route_table_id']} not found"
        exit 2
      when @conf['nodes'].count < 2
        output '2 or more nodes are required to create a quorum'
        exit 3
      end
    end

    def defaults
      { 'pings' => 3,
        'ping_timeout' => 1,
        'heartbeat_interval' => 10 }
    end

    def main_loop
      loop do
        begin
          heartbeat
        rescue => e
          output "Caught #{e.class} exception: #{e.message}"
          output e.backtrace
        end
        sleep @conf['heartbeat_interval']
      end
    end

    def heartbeat
      un = unreachable_nodes
      healthy_nodes =  @conf['nodes'].keys.count - un.count
      if am_i_master?
        output "Looks like I'm the master"

        dd_metric(healthy_nodes)
        return
      end
      if un.count == other_nodes.keys.count # return if I'm unreachable...
        output "No nodes are reachable. Seems I'm the unreachable one."
        return
      end
      cm = current_master
      unless un.include?(cm) # ...unless master is unreachable
        output "Unreachable nodes: #{un.inspect}"
        output "Current master (#{cm}) is still reachable"
        dd_metric(healthy_nodes)
        return
      end
      steal_route
    end

    def steal_route
      output 'Stealing route 0.0.0.0/0 on route table ' \
             "#{@conf['route_table_id']}"
      #return if @conf['mocking']
      connection.replace_route(
        @conf['route_table_id'],
        '0.0.0.0/0',
        'InstanceId' => my_instance_id
      )
    end

    def unreachable_nodes
      other_nodes.select { |_node, ip| !pingable?(ip) }
    end

    def other_nodes
      @other_nodes ||= begin
        nodes = @conf['nodes'].dup
        nodes.delete my_instance_id
        nodes
      end
    end

    def pingable?(ip)
      p = Net::Ping::External.new(ip)
      p.timeout = @conf['ping_timeout']
      p.ping?
    end

    def route_exists?(route_id)
      connection.route_tables.map(&:id).include? route_id
    end

    def connection
      @connection ||= begin
        if @conf['aws_access_key_id']
          options = { aws_access_key_id: @conf['aws_access_key_id'],
                      aws_secret_access_key: @conf['aws_secret_access_key'] }
        else
          options = { 
            use_iam_profile: true,
            region: @conf['region'] || 'us-east-1'
          }
        end

        options[:endpoint] = @conf['aws_url'] if @conf['aws_url']
        Fog::Compute::AWS.new(options)
      end
    end

    def current_master
      default_r =
        connection.route_tables.get(@conf['route_table_id']).routes.find do |r|
          r['destinationCidrBlock'] == '0.0.0.0/0'
        end
      default_r['instanceId']
    end

    def my_instance_id
      @my_instance_id ||= begin
        Net::HTTP.get(
          '169.254.169.254',
          '/latest/meta-data/instance-id'
        )
      end
    end

    def am_i_master?
      master_node? my_instance_id
    end

    def master_node?(node_id)
      current_master == node_id
    end

    private

    def output(message)
      puts message
      log message
    end

    def log(message, level = 'info')
      Syslog.open('nat-monitor', Syslog::LOG_PID | Syslog::LOG_CONS) do |s|
        s.send(level, message)
      end
    end

    def dd_metric(metric)
      dog = Dogapi::Client.new(@conf['dd_key'])
      dog.emit_point(
        "ec2.nat.heartbeat",
        metric,
        :host => @conf['host'],
        :tags => @conf['tags']
      )
    end
  end
end
