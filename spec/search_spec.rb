require "#{File.dirname(__FILE__)}/helper"
require 'tempfile'

describe Indy do

  context "search with string" do

    before(:each) do
      log_string = ["2000-09-07 14:07:41 INFO  MyApp - Entering APPLICATION.",
                    "2000-09-07 14:08:41 INFO  MyOtherApp - Exiting APPLICATION.",
                    "2000-09-07 14:10:55 INFO  MyApp - Exiting APPLICATION."].join("\n")
      @indy = Indy.search(log_string)
    end

    it "should return 2 records" do
      @indy.for(:application => 'MyApp').length.should == 2
    end

    it "should search entire string on each successive search" do
      @indy.for(:application => 'MyApp').length.should == 2
      @indy.for(:severity => 'INFO').length.should == 3
      @indy.for(:application => 'MyApp').length.should == 2
    end

  end

  context "search file" do

    before(:all) do
      @file = Tempfile.new('file_search_spec')
      @file.write([ "2000-09-07 14:07:41 INFO  MyApp - Entering APPLICATION.",
                    "2000-09-07 14:08:41 INFO  MyOtherApp - Exiting APPLICATION.",
                    "2000-09-07 14:10:55 INFO  MyApp - Exiting APPLICATION."
                  ].join("\n"))
      @file.flush
      @file.rewind
      @indy = Indy.search(:file => @file)
    end

    it "should return 2 records" do
      @indy.for(:application => 'MyApp').length.should == 2
    end

    it "should search entire file on each successive search" do
      @indy.for(:application => 'MyApp').length.should == 2
      @indy.for(:severity => 'INFO').length.should == 3
      @indy.for(:application => 'MyApp').length.should == 2
    end

    it "should search reopened file on each successive search" do
      @file.write("\n2000-09-07 14:10:55 INFO  MyApp - really really Exiting APPLICATION.\n")
      @file.flush
      @indy.for(:application => 'MyApp').length.should == 3
      @indy.for(:severity => 'INFO').length.should == 4
      @indy.for(:application => 'MyApp').length.should == 3
    end

  end

  context "search using cmd" do

    before(:all) do
      @file = Tempfile.new('file_search_spec')
      @file_path = @file.path
      @file.write([ "2000-09-07 14:07:41 INFO  MyApp - Entering APPLICATION.",
                    "2000-09-07 14:08:41 INFO  MyOtherApp - Exiting APPLICATION.",
                    "2000-09-07 14:10:55 INFO  MyApp - Exiting APPLICATION."
                  ].join("\n"))
      @file.flush

      cmd = is_windows? ?
        "type #{@file_path}" :
        "cat #{@file_path}"
      @indy = Indy.search(:cmd => cmd)
    end

    it "should return 2 records" do
      results = @indy.for(:application => 'MyApp')
      results.length.should == 2
      results.last.time.should == '2000-09-07 14:10:55'
      results.last.severity.should == 'INFO'
      results.last.application.should == 'MyApp'
      results.last.message.should == 'Exiting APPLICATION.'
    end

    it "should execute cmd on each successive search" do
      @indy.for(:application => 'MyApp').length.should == 2
      @indy.for(:severity => 'INFO').length.should == 3

      @file.write("\n2000-09-07 14:10:55 DEBUG MyApp - really really Exiting APPLICATION.\n")
      @file.flush

      @indy.for(:application => 'MyApp').length.should == 3
      @indy.for(:severity => 'INFO').length.should == 3
    end


  end

end
