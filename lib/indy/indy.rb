require 'ostruct'
require 'active_support/core_ext'

module Indy

  VERSION = "0.1.0"

  class Indy

    attr_accessor :source, :pattern

    DATE_TIME = "\\d{4}.\\d{2}.\\d{2}\s+\\d{2}.\\d{2}.\\d{2}" #"%Y-%m-%d %H:%M:%S"
    SEVERITY = [:trace,:debug,:info,:warn,:error,:fatal]
    SEVERITY_PATTERN = "(?:#{SEVERITY.map{|s| s.to_s.upcase}.join("|")})"
    APPLICATION = "\\w+"
    MESSAGE = ".+"
    DEFAULT_LOG_PATTERN = "^(#{DATE_TIME})\\s+(#{SEVERITY_PATTERN})\\s+(#{APPLICATION})\\s+-\\s+(#{MESSAGE})$"
    DEFAULT_LOG_FIELDS = [:time,:severity,:application,:message]
    FOREVER_AGO = DateTime.now - 200_000
    FOREVER = DateTime.now + 200_000


    #
    # Initialize Indy.
    #
    # @example
    #
    #  Indy.new(:source => LOG_FILE)
    #  Indy.new(:source => LOG_FILE,:pattern => [LOG_REGEX_PATTERN,:time,:application,:message]
    #
    def initialize(args)
      @source = @pattern = nil
      @source_info = Hash.new

      while (arg = args.shift) do
        send("#{arg.first}=",arg.last)
      end

      @time_field = ( @pattern[1..-1].include?(:time) ? :time : nil ) if @pattern

    end

    class << self

      #
      # Create a new instance of Indy with the source specified.  This allows for
      # a more fluent creation that moves into the execution.
      #
      # @param [String,Hash] source An filename or string. Use a Hash to specify a command string.
      #
      # @example
      #
      #   Indy.search("apache.log").for(:severity => "INFO")
      #   Indy.search("INFO 2000-09-07 MyApp - Entering APPLICATION.\nINFO 2000-09-07 MyApp - Entering APPLICATION.").for(:all)
      #   Indy.search(:cmd => "cat apache.log").for(:severity => "INFO")
      #
      def search(source)
        Indy.new(:source => source, :pattern => [DEFAULT_LOG_PATTERN,DEFAULT_LOG_FIELDS].flatten)
      end

    end

    #
    # Sets the source for the Indy instance.
    #
    # @param [String,Hash] source A filename or string. Use a Hash to specify a command string.
    #
    # @example
    #
    #   source("apache.log")
    #   source(:cmd => "cat apache.log")
    #   source("INFO 2000-09-07 MyApp - Entering APPLICATION.\nINFO 2000-09-07 MyApp - Entering APPLICATION.")
    #
    def source=(specified_source)

      cmd = specified_source[:cmd] rescue nil

      if cmd
        possible_source = try_as_command(cmd)
        @source_info[:cmd] = specified_source[:cmd]
      else

        possible_source = try_as_file(specified_source) unless possible_source

        if possible_source
          @source_info[:file] = specified_source
        else
          possible_source = StringIO.new(specified_source.to_s)
          @source_info[:string] = specified_source
        end
      end

      @source = possible_source
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
      @pattern = pattern_array == :default ? [DEFAULT_LOG_PATTERN,DEFAULT_LOG_FIELDS].flatten : pattern_array
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
    def search(search_criteria)
      results = ResultSet.new

      case
      when search_criteria.is_a?(Enumerable)
        results += _search do |result|
          OpenStruct.new(result) if search_criteria.reject {|criteria,value| result[criteria] == value }.empty?
        end
      when search_criteria == :all
        results += _search {|result| OpenStruct.new(result) }
      end
      
      results
    end

    alias_method :for, :search

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
        time = DateTime.parse(scope_criteria[:time])
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
        time = DateTime.parse(scope_criteria[:time])
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
        time = DateTime.parse(scope_criteria[:time])

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


    #
    # Search the source for the specific severity
    #
    # @param [String,Symbol] severity the severity of the log messages to search
    #        for within the source
    # @param [Symbol] direction by default search at the severity level, but you
    #        can specify :equal, :equal_and_above, and :equal_and_below
    #
    # @example INFO and more severe
    #
    #  Indy.search(LOG_FILE).severity('INFO',:equal_and_above)
    #
    # @example Custom Level and Below
    #
    #  Indy.search(LOG_FILE).with([CUSTOM_PATTERN,time,severity,message]).severity(:yellow,:equal_and_below,[:green,:yellow,:orange,:red])
    #  Indy.search(LOG_FILE).with([CUSTOM_PATTERN,time,severity,message]).matching(:severity => '(GREEN|YELLOW)')
    #
    def severity(severity,direction = :equal,scale = SEVERITY)
      severity = severity.to_s.downcase.to_sym

      case direction
      when :equal
        severity = [severity]
      when :equal_and_above
        severity = scale[scale.index(severity)..-1]
      when :equal_and_below
        severity = scale[0..scale.index(severity)]
      end

      ResultSet.new + _search {|result| OpenStruct.new(result) if severity.include?(result[:severity].downcase.to_sym) }

    end

    #
    # Search the specified source and yield to the block the line that was found
    # with the given log pattern
    #
    # This method is supposed to be used internally.
    # @param [IO] source is a Ruby IO object
    #
    def _search(source = @source,pattern_array = @pattern,&block)

      if @start_time || @end_time
        @start_time = @start_time || FOREVER_AGO
        @end_time = @end_time || FOREVER
      end

      if @source_info[:cmd]
        actual_source = try_as_command(@source_info[:cmd])
      else
        source.rewind
        actual_source = source.dup
      end

      results = actual_source.each.collect do |line|

        hash = parse_line(line, pattern_array)

        if @time_field && @start_time
          set_time(hash)
          next unless inside_time_window?(hash)
        end

        next unless hash
        
        block_given? ? block.call(hash) : nil
      end


      results.compact
    end

    #
    # Return a hash of field=>value pairs for the log line
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
    # Set the time in the hash
    #
    def set_time(hash)
      hash[:_time] = parse_date( hash ) if hash
    end

    #
    # Evaluate time condition
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
    # Return a valid DateTime object for the log line
    #
    def parse_date(line_hash)
      return nil unless @time_field

      begin
        DateTime.parse(line_hash[ @time_field ]) if @time_field
      rescue ArgumentError
        @time_field = nil
      end

    end

    #
    # Try opening the string as a command string, returning an IO object
    #
    def try_as_command(command_string)

      begin
        io = IO.popen(command_string)
        return nil if io.eof?
      rescue
        nil
      end
      io
    end

    #
    # Try opening the string as a file, returning an File IO Object
    #
    def try_as_file(filename)

      begin
        File.open(filename)
      rescue
        nil
      end

    end

  end

end