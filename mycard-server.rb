  require 'daemons'
  
    Daemons.run('main.rb', dir: File.dirname(__FILE__), monitor: true)
  
