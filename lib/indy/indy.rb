require 'active_support/core_ext'

class Indy

  # hash with one key (:string, :file, or :cmd) set to the string that defines the log
  attr_accessor :source

  # array with regexp string and capture groups followed by log field
  # name symbols. :time field is required to use time scoping
  attr_accessor :log_format

  # format string for explicit date/time format (optional)
  attr_accessor :time_format

  # initialization flag (true || nil) to enable multiline log entries. See README
  attr_accessor :multiline

  #
  # Initialize Indy. Also see class method Indy.search()
  #
  # @example
  #
  #  Indy.new(:source => LOG_FILE)
  #  Indy.new(:source => LOG_CONTENTS_STRING)
  #  Indy.new(:source => {:cmd => LOG_COMMAND_STRING})
  #  Indy.new(:log_format => [LOG_REGEX_PATTERN,:time,:application,:message],:source => LOG_FILE)
  #  Indy.new(:time_format => '%m-%d-%Y',:pattern => [LOG_REGEX_PATTERN,:time,:application,:message],:source => LOG_FILE)
  #
  def initialize(args)
    @source = @log_format = @time_format = @log_regexp = @log_fields = @multiline = nil
    while (arg = args.shift) do
      send("#{arg.first}=",arg.last)
    end
    update_log_format( @log_format )
  end

  #
  # Create an Indy::Source object to manage the log source
  #
  # @param [String,Hash] source A filename, or log content as a string. Use a Hash with :cmd key to specify a command string.
  #
  def source=(param)
    @source = Source.new(param)
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
    # @example filename source
    #   Indy.search("apache.log").for(:severity => "INFO")
    #   
    # @example string source
    #   Indy.search("INFO 2000-09-07 MyApp - Entering APPLICATION.\nINFO 2000-09-07 MyApp - Entering APPLICATION.").for(:all)
    #
    # @example command source
    #   Indy.search(:cmd => "cat apache.log").for(:severity => "INFO")
    #
    # @example source as well as other paramters
    #   Indy.search(:source => {:cmd => "cat apache.log"}, :log_format => LOG_FORMAT, :time_format => MY_TIME_FORMAT).for(:all)
    #
    def search(params=nil)
      if params.respond_to?(:keys) && params[:source]
        Indy.new(params)
      else
        Indy.new(:source => params, :log_format => DEFAULT_LOG_FORMAT)
      end
    end

    #
    # Return a Struct::Line object from a hash of values from a log entry
    #
    # @param [Hash] line_hash a hash of :field_name => value pairs for one log line
    #
    def create_struct( line_hash )
      params = line_hash.keys.sort_by{|e|e.to_s}.collect {|k| line_hash[k]}
      result = Struct::Line.new( *params )
      result
    end

  end


  #
  # Specify the log format to use as the comparison against each line within
  # the log file that has been specified.
  #
  # @param [Array] log_format an Array with the regular expression as the first element
  #        followed by list of fields (Symbols) in the log entry
  #        to use for comparison against each log line.
  #
  # @example Log formatted as - HH:MM:SS Message
  #
  #  Indy.search(LOG_FILE).with(/^(\d{2}.\d{2}.\d{2})\s*(.+)$/,:time,:message)
  #
  def with(log_format = :default)
    update_log_format( log_format )
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
    results += _search do |result|
      if search_criteria == :all
        result_struct = Indy.create_struct(result)
      elsif search_criteria.reject {|criteria,value| result[criteria] == value }.empty?
        result_struct = Indy.create_struct(result)
      end
      yield result_struct if block_given? and result_struct
      result_struct
    end
    results.compact
  end


  #
  # Search the source and make a regular expression comparison
  #
  # @param [Hash] search_criteria the field to search for as the key and the
  #        value to compare against the other log messages
  #
  # @example For all applications that end with Service
  #
  #  Indy.search(LOG_FILE).like(:application => '.+service')
  #
  def like(search_criteria)
    results = ResultSet.new
    results += _search do |result|
      if search_criteria.reject {|criteria,value| result[criteria] =~ /#{value}/i }.empty?
        result_struct = Indy.create_struct(result)
        yield result_struct if block_given?
      end
      result_struct
    end
    results.compact
  end

  alias_method :matching, :like


  #
  # Scopes the eventual search to the last N entries, or last N minutes of entries.
  #
  # @param [Hash] scope_criteria hash describing the amount of time at
  # the last portion of the source
  #
  # @example For last 10 minutes worth of entries
  #
  #   Indy.search(LOG_FILE).last(:span => 100).for(:all)
  #
  def last(scope_criteria)
    raise ArgumentError, "Unsupported parameter to last(): #{scope_criteria.inspect}" unless scope_criteria.respond_to?(:keys) and scope_criteria[:span]
    span = (scope_criteria[:span].to_i * 60).seconds
    starttime = parse_date(last_entries(1)) - span

    within(:time => [starttime, forever])
    self
  end


  #
  # Scopes the eventual search to all entries after to this point.
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
      @inclusive = @inclusive || scope_criteria[:inclusive] || nil
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
  # Removes any existing start and end times from the instance
  # Otherwise consecutive search calls retain time scope state
  #
  def reset_scope
    @inclusive = @start_time = @end_time = nil
  end
    
  #
  # Scopes the eventual search to all entries prior to this point.
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
      @inclusive = @inclusive || scope_criteria[:inclusive] || nil
      if scope_criteria[:span]
        span = (scope_criteria[:span].to_i * 60).seconds
        within(:time => [time - span, time], :inclusive => scope_criteria[:inclusive])
      else
        @end_time = time
      end
    end
    self
  end

  #
  # Scopes the eventual search to all entries near this point.
  #
  # @param [Hash] scope_criteria the hash containing :time and :span (in minutes) to scope the log
  #
  def around(scope_criteria)
    raise ArgumentError unless scope_criteria.respond_to?(:keys) and scope_criteria[:time]
    time = parse_date(scope_criteria[:time])
    @inclusive = nil
    mid_span = ((scope_criteria[:span].to_i * 60)/2).seconds rescue 300.seconds
    within(:time => [time - mid_span, time + mid_span])
    self
  end


  #
  # Scopes the eventual search to all entries between two times.
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
      @start_time, @end_time = scope_criteria[:time].collect {|str| parse_date(str) }
      @inclusive = @inclusive || scope_criteria[:inclusive] || nil
    end
    self
  end


  private

  #
  # Set @pattern as well as @log_regexp, @log_fields, and @time_field
  #
  # @param [Array] pattern_array an Array with the regular expression as the first element
  #        followed by list of fields (Symbols) in the log entry
  #        to use for comparison against each log line.
  #
  def update_log_format( log_format )
    case log_format
    when :default, nil
      @log_format = DEFAULT_LOG_FORMAT
    else
      @log_format = log_format
    end
    @log_regexp, *@log_fields = @log_format
    @time_field = ( @log_fields.include?(:time) ? :time : nil )
    # now that we know the fields
    define_struct
  end

  #
  # Search the @source and yield to the block the line that was found
  # with @log_regexp and @log_fields
  #
  # This method is supposed to be used internally.
  #
  def _search(&block)
    if @multiline
      multiline_search(&block)
    else
      standard_search(&block)
    end
  end

  #
  # Performs #_search for line based entries
  #
  def standard_search(&block)
    is_time_search = use_time_criteria?
    results = ResultSet.new
    source_lines = (is_time_search ? @source.open([@start_time,@end_time]) : @source.open)
    source_lines.each do |line|
      hash = parse_line(line)
      next unless hash
      next unless inside_time_window?(hash) if is_time_search
      results << (block.call(hash) if block_given?)
    end
    results.compact
  end

  #
  # Performs #_search for multi-line based entries
  #
  def multiline_search(&block)
    is_time_search = use_time_criteria?
    source_io = StringIO.new( (is_time_search ? @source.open([@start_time,@end_time]) : @source.open ).join("\n") )
    results = source_io.read.scan(Regexp.new(@log_regexp, Regexp::MULTILINE)).collect do |entry|
      hash = parse_line_captures(entry)
      next unless hash
      next unless inside_time_window?(hash) if is_time_search
      block.call(hash) if block_given?
    end
    results.compact
  end

  #
  # Return a hash of field=>value pairs for the log line
  #
  # @param [String] line The log line
  #
  def parse_line(line)
    match_data = /#{@log_regexp}/.match(line)
    return nil unless match_data
    values = match_data.captures
    assert_valid_field_list(values)
    make_line_hash([line, values].flatten)
  end

  #
  # Return a hash of field=>value pairs for the captured values from a log line
  #
  # @param [String] capture_array The array of values captured by the @log_regexp
  #
  def parse_line_captures( capture_array )
    entire_line = capture_array.shift
    values = capture_array
    assert_valid_field_list(capture_array)
    make_line_hash([entire_line, values].flatten)
  end

  #
  # Convert log entry into hash
  #
  def make_line_hash(values)
    entire_line = values.shift
    hash = Hash[ *@log_fields.zip( values ).flatten ]
    hash[:line] = entire_line.strip
    hash
  end

  #
  # Ensure number of fields is expected
  #
  def assert_valid_field_list(values)
    raise "Field mismatch between log pattern and log data. The data is: '#{values.join(':::')}'" unless values.length == @log_fields.length
  end

  #
  #  Return true if start or end time has been set, and a :time field exists
  #
  def use_time_criteria?
    if @start_time || @end_time
      # ensure both boundaries are set
      @start_time = @start_time || forever_ago
      @end_time = @end_time || forever
    end
    @time_field && @start_time && @end_time
  end

  #
  # Evaluate if a log line satisfies the configured time conditions
  #
  # @param [Hash] line_hash The log line hash to be evaluated
  #
  def inside_time_window?( line_hash )
    time = parse_date( line_hash )
    return false unless time && line_hash
    if @inclusive
      true unless time > @end_time or time < @start_time
    else
      true unless time >= @end_time or time <= @start_time
    end
  end

  #
  # Return a valid DateTime object for the log line or string
  #
  # @param [String, Hash] param The log line hash, or string to be evaluated
  #
  def parse_date(param)
    return nil unless @time_field
    return param if param.kind_of? Time or param.kind_of? DateTime
    time_string = param.is_a?(Hash) ? param[@time_field] : param.to_s
    if @time_format
      begin
        # Attempt the appropriate parse method
        DateTime.strptime(time_string, @time_format)
      rescue
        # If appropriate, fall back to simple parse method
        DateTime.parse(time_string) rescue nil
      end
    else
      begin
        Time.parse(time_string)
      rescue Exception => e
        raise "Failed to create time object. The error was: #{e.message}"
      end
    end
  end

  #
  # Return a time or datetime object way in the future
  #
  def forever
    @time_format ? DateTime.new(4712) : Time.at(0x7FFFFFFF)
  end

  #
  # Return a time or datetime object way in the past
  #
  def forever_ago
    begin
      @time_format ? DateTime.new(-4712) : Time.at(-0x7FFFFFFF)
    rescue
      # Windows Ruby Time can't handle dates prior to 1969
      @time_format ? DateTime.new(-4712) : Time.at(0)
    end
  end

  #
  # Define Struct::Line with the fields configured with @pattern. Ignore warnings.
  #
  def define_struct
    fields = (@log_fields + [:line]).sort_by{|e|e.to_s}
    verbose = $VERBOSE
    $VERBOSE = nil
    Struct.new( "Line", *fields )
    $VERBOSE = verbose
  end

  #
  # Return an array of Struct::Line entries for the last N valid entries from the source
  #
  # @param [Fixnum] num the number of rows to retrieve
  #
  def last_entries(num)
    num_entries = 0
    result = []
    source_io = @source.open
    source_io.reverse_each do |line|
      hash = parse_line(line)
      if hash
        num_entries += 1
        result << hash
        break if num_entries >= num
      end
    end
    warn "#last_entries found no matching lines in source." if result.empty?
    num == 1 ? Indy.create_struct(result.first) : result.collect{|e| Indy.create_struct(e)}
  end

end
