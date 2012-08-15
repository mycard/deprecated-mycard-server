#!/usr/bin/env ruby
require 'eventmachine'
require 'em-http-request'
require 'mysql2'
require 'mysql2/em'
require 'json'
require 'logger'
require 'open-uri'
require 'yaml'

Config = 'config.yml'
Config.replace File.expand_path Config, File.dirname(__FILE__)
$config  = YAML.load_file Config
#open($config['api']) do |f|
#$config['servers'] = JSON.parse f.read
#  open(Config, 'w') { |conf| YAML.dump $config, conf }
#end rescue puts $!

$servers = $config["servers"].collect { |server| {id: server["id"], name: server["name"], ip: server["ip"], port: server["port"], http_port: server["http_port"], index: server['index'], max_rooms: server['max_rooms'], cache: []} }
puts YAML.dump $config

Windows = RUBY_PLATFORM['ming'] || RUBY_PLATFORM['mswin']

Mysql = (Windows ? Mysql2::Client : Mysql2::EM::Client).new(
    host:     $config["db"]["host"],
    username: $config["db"]["username"],
    password: $config["db"]["password"],
    database: $config["db"]["database"],
)
if Windows
  def Mysql.result(sql, &block)
    yield Mysql.query(sql)
  end
else
  def Mysql.result(sql, &block)
    Mysql.query(sql).callback &block
  end
end

Logged_Users = {}


Dir.chdir(File.dirname(__FILE__))
$log = Logger.new(STDOUT)
$log.info 'server started'

module MycardSever
  include EM::P::ObjectProtocol
  Connections = {}

  def post_init
    'puts connect'
  end

  def receive_data data
    super rescue nil
  end

  def receive_object obj
    $log.debug obj
    begin
      data = obj[:data]
      case obj[:header]
      when :login
        conn = self
        $log.info "login #{data[:name]}"
        Mysql.result("SELECT * FROM users WHERE name = '#{Mysql.escape data[:name]}' and password = '#{data[:password]}' limit 1") do |result|
          @user = nil
          result.each do |row|
            @user = {id: row["id"], name: row["name"], nickname: row["nickname"], certified: true}
          end
          if @user
            $log.info("login success 2") { data }
            Logged_Users[@user[:id]] = @user
            Connections[@user[:id]]  = conn
          else
            $log.info("login failed 3") { data }
          end
          send_object header: :login, data: @user
        end
      when :refresh
        rooms = []
        $servers.each do |server|
          rooms += server[:cache]
        end
        send_object header: :rooms, data: rooms
        send_object header: :servers, data: $servers
      when :chat
        $log.info "chat #{@user}"
        data[:from] = @user
        if data[:channel] == :lobby
          Connections.each do |key, value|
            next if key == @user[:id]
            value.send_object header: :chat, data: data
          end
        else
          channel        = data[:channel]
          data[:channel] = @user[:id]
          Connections[channel].send_object header: :chat, data: data if Connections[channel]
        end
      else
        $log.info 'inavilid data: ' + obj.inspect
      end
    rescue Exception => exception
      $log.info 'error: ' + obj.inspect + exception.inspect + exception.backtrace.inspect
    end
  end

  def unbind
    begin
      if @user
        $log.info "disconnect #{@user}"
        Logged_Users.delete @user[:id]
        Connections.delete @user[:id]
      end
    rescue Exception => exception
      $log.info 'error: ' + exception.inspect + exception.inspect + exception.backtrace.inspect
    end
  end

  def self.boardcast(obj)
    Connections.each do |key, value|
      value.send_object obj
    end
  end

  def self.refresh(server, reply)
    reply.force_encoding("GBK").encode!("UTF-8", :invalid => :replace, :undef => :replace)
    reply = JSON.parse reply rescue {}
    return unless reply["rooms"]
    rooms         = reply["rooms"].collect { |room| parse_room(server, room) }
    rooms_changed = rooms - server[:cache] + (server[:cache] - rooms).collect { |room| room[:_deleted] = true; room }
    return if rooms_changed.empty?
    $log.info("rooms_update_#{server[:name]}") { rooms_changed }
    boardcast header: :rooms_update, data: rooms_changed
    server[:cache].replace rooms
  end

  def self.parse_room(server, room)
    id = ('A'.ord+server[:id]).chr + room["roomid"]
    decode(room["roomname"]) =~ /^(P)?(M)?(T)?\#?(.*)$/
    result = {id: id, name: $4, status: room["istart"].to_sym, pvp: !!$1, match: !!$2, tag: !!$3, lp: 8000, private: room["needpass"] == "true", server_id: server[:id], server_ip: server[:ip], server_port: server[:port]}
    if result[:name] =~ /^(\d)(\d)(F)(F)(F)(\d+),(\d+),(\d+),(.*)$/
      result[:ot]    = $1.to_i
      result[:match] = $2 == "1"
      result[:tag]   = $2 == "2"
      result[:lp]    = $6.to_i
      result[:name]  = $9
    end
    room["users"].each do |user|
      case user["pos"].to_i
      when 0, 16
        result[:player1] = parse_user(user)
      when 1, 17
        result[:player2] = parse_user(user)
      end
    end
    result
  end

  def self.parse_user(user)
    name = decode(user["name"])
    {id: name.to_sym, name: name, nickname: name, certified: user["id"]=="-1"}
  end

  def self.decode(str)
    [str].pack('H*').force_encoding("UTF-16BE").encode("UTF-8", :undef => :replace, :invalid => :replace)
  end
end


begin
  EventMachine::run {
    EventMachine::start_server "0.0.0.0", $config["port"], MycardSever
    EM.add_periodic_timer(2) do
      $servers.each_with_index do |server, index|
        http = EM::HttpRequest.new(server[:index] + '?operation=getroomjsondelphi').get
        http.callback {
          MycardSever.refresh(server, http.response)
        }
      end
    end
  }
rescue
  $log.error 'error: ' + $!.inspect + $!.backtrace.inspect
  retry
end
