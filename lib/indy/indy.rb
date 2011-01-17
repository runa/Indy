require 'ostruct'
require 'active_support/core_ext'

class Indy

  VERSION = "0.1.1"

  #
  # hash with one key (:string, :file, or :cmd) set to the string that defines the log
  #
  attr_accessor :source

  #
  # array with regexp string and capture groups followed by log field
  # name symbols. :time field is required to use time scoping
  #
  attr_accessor :pattern

  #
  # format string for explicit date/time format (optional)
  #
  attr_accessor :time_format

  FOREVER_AGO = DateTime.now - 200_000
  FOREVER = DateTime.now + 200_000


  #
  # Initialize Indy.
  #
  # @example
  #
  #  Indy.new(:source => LOG_FILENAME)
  #  Indy.new(:source => LOG_CONTENTS_STRING)
  #  Indy.new(:source => {:cmd => LOG_COMMAND_STRING})
  #  Indy.new(:pattern => [LOG_REGEX_PATTERN,:time,:application,:message],:source => LOG_FILENAME)
  #  Indy.new(:time_format => '%m-%d-%Y',:pattern => [LOG_REGEX_PATTERN,:time,:application,:message],:source => LOG_FILENAME)
  #
  def initialize(args)
    @source = @pattern = nil
    @source = Hash.new

    while (arg = args.shift) do
      send("#{arg.first}=",arg.last)
    end

    @pattern = @pattern || DEFAULT_LOG_PATTERN
    @time_field = ( @pattern[1..-1].include?(:time) ? :time : nil )

  end

  class << self

    #
    # Create a new instance of Indy with @source, or multiple, parameters
    # specified.  This allows for a more fluent creation that moves 
    # into the execution.
    #
    # @param [String,Hash] params To specify @source, provide a filename or
    #   log contents as a string. To specify a command, use a :cmd => STRING hash.
    #   Alternately, a Hash with a :source key (amoung others) can be used to
    #   provide multiple initialization parameters.
    #
    # @example
    #   Indy.search("apache.log").for(:severity => "INFO")
    #   
    # @example
    #   Indy.search("INFO 2000-09-07 MyApp - Entering APPLICATION.\nINFO 2000-09-07 MyApp - Entering APPLICATION.").for(:all)
    #
    # @example
    #   Indy.search(:cmd => "cat apache.log").for(:severity => "INFO")
    #
    # @example
    #   Indy.search(:source => {:cmd => "cat apache.log"}, :pattern => LOG_PATTERN, :time_format => MY_TIME_FORMAT).for(:all)
    #
    def search(params)
      if params.respond_to?(:keys) && params[:source]
        Indy.new(params)
      else
        Indy.new(:source => params, :pattern => DEFAULT_LOG_PATTERN)
      end
    end

  end



  #
  # Specify the log pattern to use as the comparison against each line within
  # the log file that has been specified.
  #
  # @param [Array] pattern_array an Array with the regular expression as the first element
  #        followed by list of fields (Symbols) in the log entry
  #        to use for comparison against each log line.
  #
  # @example Log formatted as - HH:MM:SS Message
  #
  #  Indy.search(LOG_FILE).with("^(\\d{2}.\\d{2}.\\d{2})\s*(.+)$",:time,:message)
  #
  def with(pattern_array = :default)
    @pattern = pattern_array == :default ? DEFAULT_LOG_PATTERN : pattern_array
    @time_field = @pattern[1..-1].include?(:time) ? :time : nil
    self
  end

  #
  # Search the source and make an == comparison
  #
  # @param [Hash,Symbol] search_criteria the field to search for as the key and the
  #        value to compare against the other log messages.  This function also
  #        supports symbol :all to return all messages
  #
  def for(search_criteria)
    results = ResultSet.new

    case search_criteria
    when Enumerable
      results += _search do |result|
        OpenStruct.new(result) if search_criteria.reject {|criteria,value| result[criteria] == value }.empty?
      end
    when :all
      results += _search {|result| OpenStruct.new(result) }
    end

    results
  end


    #
    # Search the source and make a regular expression comparison
    #
    # @param [Hash] search_criteria the field to search for as the key and the
    #        value to compare against the other log messages
    #
    # @example For all applications that end with Service
    #
    #  Indy.search(LOG_FILE).like(:application => '(.+)Service')
    #
    def like(search_criteria)
      results = ResultSet.new

      results += _search do |result|
        OpenStruct.new(result) if search_criteria.reject {|criteria,value| result[criteria] =~ /#{value}/ }.empty?
      end

      results
    end

    alias_method :matching, :like


    #
    # After scopes the eventual search to all entries after to this point.
    #
    # @param [Hash] scope_criteria the field to scope for as the key and the
    #        value to compare against the other log messages
    #
    # @example For all messages after specified date
    #
    #   Indy.search(LOG_FILE).after(:time => time).for(:all)
    #
    def after(scope_criteria)
      if scope_criteria[:time]
        time = parse_date(scope_criteria[:time])
        @inclusive = scope_criteria[:inclusive] || false

        if scope_criteria[:span]
          span = (scope_criteria[:span].to_i * 60).seconds
          within(:time => [time, time + span])
        else
          @start_time = time
        end
      end

      self
    end

    #
    # Before scopes the eventual search to all entries prior to this point.
    #
    # @param [Hash] scope_criteria the field to scope for as the key and the
    #        value to compare against the other log messages
    #
    # @example For all messages before specified date
    #
    #   Indy.search(LOG_FILE).before(:time => time).for(:all)
    #   Indy.search(LOG_FILE).before(:time => time, :span => 10).for(:all)
    #
    def before(scope_criteria)
      if scope_criteria[:time]
        time = parse_date(scope_criteria[:time])
        @inclusive = scope_criteria[:inclusive] || false

        if scope_criteria[:span]
          span = (scope_criteria[:span].to_i * 60).seconds
          within(:time => [time - span, time], :inclusive => scope_criteria[:inclusive])
        else
          @end_time = time
        end
      end

      self
    end

    def around(scope_criteria)
      if scope_criteria[:time]
        time = parse_date(scope_criteria[:time])

        # does @inclusive add any real value to the #around method?
        @inclusive = scope_criteria[:inclusive] || false

        half_span = ((scope_criteria[:span].to_i * 60)/2).seconds rescue 300.seconds
        within(:time => [time - half_span, time + half_span])
      end

      self
    end


    #
    # Within scopes the eventual search to all entries between two points.
    #
    # @param [Hash] scope_criteria the field to scope for as the key and the
    #        value to compare against the other log messages
    #
    # @example For all messages within the specified dates
    #
    #   Indy.search(LOG_FILE).within(:time => [start_time,stop_time]).for(:all)
    #
    def within(scope_criteria)
      if scope_criteria[:time]
        @start_time, @end_time = scope_criteria[:time]
        @inclusive = scope_criteria[:inclusive] || false
      end

      self
    end


    private

    #
    # Sets the source for the Indy instance.
    #
    # @param [String,Hash] source A filename, or log content as a string. Use a Hash with :cmd key to specify a command string.
    #
    # @example
    #
    #   source("apache.log")
    #   source(:cmd => "cat apache.log")
    #   source("INFO 2000-09-07 MyApp - Entering APPLICATION.\nINFO 2000-09-07 MyApp - Entering APPLICATION.")
    #
    def source=(param)

      cmd = param[:cmd] rescue nil
      @source[:cmd] = param[:cmd] if cmd

      unless cmd
        File.exist?(param) ? @source[:file] = param : @source[:string] = param
      end

    end

    #
    # Search the @source and yield to the block the line that was found
    # with @pattern
    #
    # This method is supposed to be used internally.
    #
    def _search(&block)
      time_search = use_time_criteria?
      source_io = open_source

      results = source_io.each.collect do |line|

        hash = parse_line(line, @pattern)

        if time_search
          set_time(hash)
          next unless inside_time_window?(hash)
        end
        next unless hash

        block_given? ? block.call(hash) : nil

      end

      source_io.close if @source[:file] || @source[:cmd]

      results.compact
    end


    #
    # Return a log io object
    #
    def open_source
      begin

        case @source.keys.first # and only
        when :cmd
          source_io = exec_command(@source[:cmd])
          raise "Failed to execute command (#{@source[:cmd]})" if source_io.nil?

        when :file
          source_io = File.open(@source[:file], 'r')
          raise "Filed to open file: #{@source[:file]}" if source_io.nil?

        when :string
          source_io = StringIO.new( @source[:string] )

        else
          raise "Unsupported log source: #{@source.inspect}"
        end

      rescue Exception => e
        raise "Unable to open log source. (#{e.message})"
      end

      source_io
    end

    #
    # Return a hash of field=>value pairs for the log line
    #
    # @param [String] line The log line
    # @param [Array] pattern_array The match regexp string, followed by log fields
    #   see Class method search
    #
    def parse_line( line, pattern_array = @pattern)
      regexp, *fields = pattern_array

      if /#{regexp}/.match(line)
        values = /#{regexp}/.match(line).captures
        raise "Field mismatch between log pattern and log data. The data is: '#{values.join(':::')}'" unless values.length == fields.length

        hash = Hash[ *fields.zip( values ).flatten ]
        hash[:line] = line.strip

        hash
      end
    end

    #
    #  Return true if start or end time has been set, and a :time field exists
    #
    def use_time_criteria?
      if @start_time || @end_time
        # ensure both boundaries are set
        @start_time = @start_time || FOREVER_AGO
        @end_time = @end_time || FOREVER
      end

      return (@time_field && @start_time && @end_time)
    end


    #
    # Set the :_time value in the hash
    #
    # @param [Hash] hash The log line hash to modify
    #
    def set_time(hash)
      hash[:_time] = parse_date( hash ) if hash
    end

    #
    # Evaluate if a log line satisfies the configured time conditions
    #
    # @param [Hash] line_hash The log line hash to be evaluated
    #
    def inside_time_window?( line_hash )

      if line_hash && line_hash[:_time]
        if @inclusive
          true unless line_hash[:_time] > @end_time or line_hash[:_time] < @start_time
        else
          true unless line_hash[:_time] >= @end_time or line_hash[:_time] <= @start_time
        end
      end

    end

    #
    # Return a valid DateTime object for the log line or string
    #
    # @param [String, Hash] param The log line hash, or string to be evaluated
    #
    def parse_date(param)
      return nil unless @time_field

      time_string = param[@time_field] ? param[@time_field] : param

      begin
        # Attempt the appropriate parse method
        @time_format ? DateTime.strptime(time_string, @time_format) : DateTime.parse(time_string)
      rescue
        # If appropriate, fall back to simple parse method
        DateTime.parse(time_string) if @time_format rescue nil
      end
    end

    #
    # Try opening the string as a command string, returning an IO object
    #
    # @param [String] command_string string of command that will return log contents
    #
    def exec_command(command_string)

      begin
        io = IO.popen(command_string)
        return nil if io.eof?
      rescue
        nil
      end
      io
    end


  end
