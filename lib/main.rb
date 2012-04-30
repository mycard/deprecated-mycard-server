#!/usr/bin/env ruby

require 'eventmachine'
require 'mysql2'
require 'json'
require 'logger'
require 'open-uri'
require 'yaml'

$config = YAML.load_file 'config.yml'
puts YAML.dump $config
$servers = $config["servers"].collect{|server|{ip: server["ip"], port: server["port"], http_port: server["http_port"]}}

Mysql = Mysql2::Client.new(host: $config["db"]["host"], username: $config["db"]["username"], password: $config["db"]["password"]) rescue nil
Mysql.query('use `mycard_production`') rescue nil
Rooms = []
Rooms_Unparsed = {}
Users = []
LastReply = []
Error_Count = []
$servers.each do
	Rooms << {}
	Users << {}
	LastReply << ""
	Error_Count << 0
end
Users_Name = {}

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
    p 0
    $log.debug obj
    begin
      data = obj[:data]
      case obj[:header]
      when :login
        conn = self
        $log.info "login #{data[:name]}"
        @user = nil
        begin
          Mysql.query("SELECT * FROM users WHERE name = '#{Mysql.escape data[:name]}' and password = '#{data[:password]}' limit 1").each{|row|@user = {id: row["id"], name: row["name"], nickname: row["nickname"], certified: true}} rescue nil
          if @user
            $log.info("login success 2"){data}
            Users[@user[:id]] = Logged_Users[@user[:id]] = @user
            Connections[@user[:id]] = conn
          else
            $log.info("login failed 3"){data}
          end
          p 1
          send_object header: :login, data: @user
        rescue
          http2 = EventMachine::Protocols::HttpClient.request(
            :host => "localhost",
            :port => "7922",
            :request => "/",
            :query_string => "operation=passcheck&username=#{CGI.escape data[:name]}&pass=#{CGI.escape data[:password]}"
          )
          http2.callback {|response|
            if response[:content] == "true"
              $log.info("login success 4"){data}
              @user = {id: data[:name].to_sym, name: data[:name], nickname: data[:name]}
              Logged_Users[@user[:id]] = @user
              Connections[@user[:id]] = conn
              send_object header: :login, data: @user
            else
              $log.info("login failed 5"){data}
              send_object header: :login, data: nil
            end
            http2.errback {
              $log.info("login failed 6"){data}
              conn.close_connection
            }
          }
        end
      when :refresh
        return unless @user
        users = Logged_Users.values
        $servers.each_with_index do |server, index|
        	users |= Users[index].values
        end
        rooms = []
        $servers.each_with_index do |server, index|
        	rooms |= Rooms[index].values
        end
        send_object header: :users, data: users
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
          channel = data[:channel]
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
  def self.refresh(server_index, reply)
    return if LastReply[server_index] == reply
    LastReply[server_index].replace reply unless reply.nil?
    reply.replace reply.force_encoding("GBK").encode("UTF-8", :invalid => :replace, :undef => :replace)
    begin
    	reply = JSON.parse reply
    	Error_Count[server_index] = 0
    rescue 
    	$log.error("server ##{server_index} inavalid reply #{Error_Count[server_index]}"){reply.encode("UTF-8", :invalid => :replace, :undef => :replace)}
    	reply = nil
    	return Error_Count[server_index] += 1 if Error_Count[server_index] < 5
    end
    rooms = {}
    users = {}
    reply["rooms"].each do |room|
      room = parseroom(server_index, room)
      rooms[room[:id]] = room
      users[room[:player1][:id]] = room[:player1] if room[:player1]
      users[room[:player2][:id]] = room[:player2] if room[:player2]
    end if reply and reply["rooms"]
    (Users[server_index].values - users.values).each {|user|Users_Name.delete user[:name]; boardcast header: :missinguser, data: user}
    (Rooms[server_index].values - rooms.values).each {|room|Rooms_Unparsed.delete room[:id]; boardcast header: :missingroom, data: room}
    Users[server_index].replace users
    Rooms[server_index].replace rooms
  end
  def self.parseroom(server_index, room)
    id = ('A'.ord+server_index).chr + room["roomid"]
    return Rooms[server_index][id] if Rooms_Unparsed[id] == room
    Rooms_Unparsed[id] = room
    room["roomname"] =~ /^(P)?(M)?\#?(.*)\$?(.*)?$/
    result = {id: id, name: $3, status: room["istart"].to_sym, pvp: !!$1, match: !!$2, password: !!$4, server_ip: $servers[server_index][:ip], server_port: $servers[server_index][:port]}
    room["users"].each do |user|
      pos = user["pos"].to_i
      user = parseuser(server_index, user)
      if pos == 0 or pos == 16
        result[:player1] = user
      elsif pos == 1 or pos == 17
        result[:player2] = user
      end
    end
    boardcast header: :newroom, data: result
    Rooms[server_index][id] = result
  end
  def self.parseuser(server_index, user)
    name = user["name"]
    return Users_Name[name] if Users_Name[name]
    if Users_Name[name]
      id = Users_Name[name][:id]
      nickname = Users_Name[name][:nickname]
    else
      id = nil
      Mysql.query("SELECT * FROM users WHERE name = '#{Mysql.escape name}' limit 1").each{|row|break (id, nickname = row["id"], row["nickname"])} rescue nil
      
      id ||= name.to_sym
      nickname ||= ""
    end
    result = {id: id, name: name, nickname: nickname, certified: user["id"]=="-1"}

    boardcast header: :newuser, data: result
    Users_Name[name] = Users[server_index][id] = result
    result
  end
end


begin
  EventMachine::run {
    EventMachine::start_server "0.0.0.0", $config["port"], MycardSever
    EM.add_periodic_timer(0.5) do
      p Time.now
      $servers.each_with_index do |server, index|
        http = EventMachine::Protocols::HttpClient.request(
          :host => server[:ip],
          :port => server[:http_port],
          :request => "/",
          :query_string => "operation=getroomjson"
        )
        http.callback {|response|
          MycardSever.refresh(index, response[:content])
        }
        http.errback {MycardSever.refresh(index, "")}
      end
    end
  }
rescue Exception => exception
  $log.error 'error: ' + exception.inspect + exception.backtrace.inspect
end