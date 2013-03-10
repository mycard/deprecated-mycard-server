#!/usr/bin/env node
inteval = 2000

_ = require 'underscore'
config = require 'yaml-config'
request = require 'request'
WebSocketServer = require('websocket').server
http = require 'http'

Iconv = require('iconv').Iconv
gbk_to_utf8 = new Iconv 'GBK', 'UTF-8//TRANSLIT//IGNORE'

settings = config.readConfig process.cwd() + '/' + "config.yaml"
console.log settings
request settings.servers, (error, response, body)->
  servers = JSON.parse body

  for s in servers
    s.rooms = []
  clients = []

  server = http.createServer (request, response)->
    console.log((new Date()) + ' Received request for ' + request.url)
    response.writeHead(200, {'Content-Type': 'application/json'});
    response.end(JSON.stringify(_.flatten(_.pluck(servers, 'rooms'))), 'utf8')

  server.listen settings.port, ->
    console.log('Server is listening on port ' + settings.port)

  wsServer = new WebSocketServer
    httpServer: server
    autoAcceptConnections: false

  originIsAllowed = (origin)->
    return true

  wsServer.on 'request', (request)->
    if (!originIsAllowed(request.origin))
      request.reject()
      console.log((new Date()) + ' Connection from origin ' + request.origin + ' rejected.')
      return

    connection = request.accept(null, request.origin)
    clients.push(connection)
    console.log((new Date()) + ' Connection accepted.')
    connection.sendUTF JSON.stringify _.flatten _.pluck(servers, 'rooms'), true

    connection.on 'close', (reasonCode, description)->
      console.log("#{new Date()} Peer #{connection.remoteAddress} disconnected: #{description}")
      index = clients.indexOf(connection)
      clients.splice(index, 1) unless index == -1

  main = (servers)->
    _.each servers, (server)->
      request {url: server.index + '/?operation=getroomjson', timeout: inteval, encoding: (if server.encoding == 'GBK' then 'binary' else 'utf8'), json: server.encoding != 'GBK'}, (error, response, body)->
        if error
          console.log error
        else
          try
            if server.encoding == 'GBK'
              refresh(server, JSON.parse gbk_to_utf8.convert(new Buffer(body, 'binary')).toString())
            else
              refresh(server, body)
          catch e
            console.log e.stack, error, response, body

  send = (data)->
    data = JSON.stringify data
    for client in clients
      client.sendUTF data

  refresh = (server, data)->
    rooms = (parse_room(server, room) for room in data.rooms)
    rooms_changed = (room for room in rooms when !_.isEqual room, _.find server.rooms, (r)->
      r.id == room.id).concat ((room._deleted = true; room) for room in server.rooms when _.all rooms, (r)->(r.id != room.id))
    if rooms_changed.length
      send rooms_changed
      server.rooms = rooms
    console.log server.name, rooms_changed.length                                                                                                   1

  parse_room = (server, data)->
    #struct HostInfo {
    #  unsigned int lflist;
    #  unsigned char rule;
    #  unsigned char mode;
    #  bool enable_priority;
    #  bool no_check_deck;
    #  bool no_shuffle_deck;
    #  unsigned int start_lp;
    #  unsigned char start_hand;
    #  unsigned char draw_count;
    #  unsigned short time_limit;
    #};
    matched = data.roomname.match /^(P)?(M)?(T)?\#?(.*)$/
    result = {
    id: String.fromCharCode('A'.charCodeAt() + server.id) + data.roomid,
    name: matched[4],
    status: data.istart
    server_id: server.id

    #pvp: matched[1]?
    #private: data.needpass == "true",

    #lflist: 0,
    #rule: 0,
    #mode: matched[2] ? matched[3] ? 2 : 1 : 0,
    #enable_priority: false,
    #no_check_deck: false,
    #no_shuffle_deck: false,
    #start_lp: 8000,
    #start_hand: => 5,
    #draw_count: => 1,
    #time_limit: => 0,

    users: []
    }
    for user_data in data.users
      user = parse_user(server, user_data)
      if (user.player == 7) or !_.some(result.users, (existed_user) ->
        existed_user.player == user.player)
        result.users.push user

    result.pvp = true if matched[1]
    result['private'] = true if data.needpass == "true"

    if matched[2]
      result.mode = 1
    else if matched[3]
      result.mode = 2
    else if matched = result.name.match /^(\d)(\d)(F)(F)(F)(\d+),(\d+),(\d+),(.*)$/
      result.name = matched[9]

      result.rule = parseInt matched[1]
      result.mode = parseInt matched[2]
      #enable_priority: false,
      #no_check_deck: false,
      #no_shuffle_deck: false,
      result.start_lp = parseInt matched[6]
      result.start_hand = parseInt matched[7]
      result.draw_count = parseInt matched[8]

    result

  #define NETPLAYER_TYPE_PLAYER1 0
  #define NETPLAYER_TYPE_PLAYER2 1
  #define NETPLAYER_TYPE_PLAYER3 2
  #define NETPLAYER_TYPE_PLAYER4 3
  #define NETPLAYER_TYPE_PLAYER5 4
  #define NETPLAYER_TYPE_PLAYER6 5
  #define NETPLAYER_TYPE_OBSERVER 7

  parse_user = (server, data)->
    {
    id: data.name,
    name: data.name,
    #nickname: data.name,
    certified: data.id == "-1",
    player: data.pos & 0xf
    }

  main servers
  setInterval ->
    main servers
  , inteval

