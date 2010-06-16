require File.join(File.dirname(__FILE__), '..', 'spec_helper')

shared_examples_for "parser type registration" do
  before do
    class MyParser < Parser::Base; end
  end
  
  after do
    Parser::SourceParser.parser_types.delete(:my_parser)
    Parser::SourceParser.parser_type_extensions.delete(:my_parser)
  end
end

describe YARD::Parser::SourceParser do
  before do 
    Registry.clear
  end
  
  describe '.register_parser_type' do
    it_should_behave_like "parser type registration"
    
    it "should register a subclass of Parser::Base" do
      parser = mock(:parser)
      parser.should_receive(:parse)
      MyParser.should_receive(:new).with('content', '(stdin)').and_return(parser)
      Parser::SourceParser.register_parser_type(:my_parser, MyParser, 'myparser')
      Parser::SourceParser.parse_string('content', :my_parser)
    end
    
    it "should require class to be a subclass of Parser::Base" do
      lambda { Parser::SourceParser.register_parser_type(:my_parser, String) }.should raise_error(ArgumentError)
      lambda { Parser::SourceParser.register_parser_type(:my_parser, Parser::Base) }.should raise_error(ArgumentError)
    end
  end
  
  describe '.parser_type_for_extension' do 
    it_should_behave_like "parser type registration"

    it "should find an extension in a registered array of extensions" do
      Parser::SourceParser.register_parser_type(:my_parser, MyParser, ['a', 'b', 'd'])
      Parser::SourceParser.parser_type_for_extension('a').should == :my_parser
      Parser::SourceParser.parser_type_for_extension('b').should == :my_parser
      Parser::SourceParser.parser_type_for_extension('d').should == :my_parser
      Parser::SourceParser.parser_type_for_extension('c').should_not == :my_parser
    end
    
    it "should find an extension in a Regexp" do
      Parser::SourceParser.register_parser_type(:my_parser, MyParser, /abc$/)
      Parser::SourceParser.parser_type_for_extension('dabc').should == :my_parser
      Parser::SourceParser.parser_type_for_extension('dabcd').should_not == :my_parser
    end
    
    it "should find an extension in a list of Regexps" do
      Parser::SourceParser.register_parser_type(:my_parser, MyParser, [/ab$/, /abc$/])
      Parser::SourceParser.parser_type_for_extension('dabc').should == :my_parser
      Parser::SourceParser.parser_type_for_extension('dabcd').should_not == :my_parser
    end
    
    it "should find an extension in a String" do
      Parser::SourceParser.register_parser_type(:my_parser, MyParser, "abc")
      Parser::SourceParser.parser_type_for_extension('abc').should == :my_parser
      Parser::SourceParser.parser_type_for_extension('abcd').should_not == :my_parser
    end
  end
  
  describe '#parse_string' do
    it "should parse basic Ruby code" do
      YARD.parse_string(<<-eof)
        module Hello
          class Hi
            # Docstring
            # Docstring2
            def me; "VALUE" end
          end
        end
      eof
      Registry.at(:Hello).should_not == nil
      Registry.at("Hello::Hi#me").should_not == nil
      Registry.at("Hello::Hi#me").docstring.should == "Docstring\nDocstring2"
      Registry.at("Hello::Hi#me").docstring.line_range.should == (3..4)
    end
    
    it "should only use prepended comments for an object" do
      YARD.parse_string(<<-eof)
        # Test
        
        # PASS
        module Hello
        end # FAIL
      eof
      Registry.at(:Hello).docstring.should == "PASS"
    end
    
    it "should not add comments appended to last line of block" do
      YARD.parse_string <<-eof
        module Hello2
        end # FAIL
      eof
      Registry.at(:Hello2).docstring.should be_blank
    end
    
    it "should add comments appended to an object's first line" do
      YARD.parse_string <<-eof
        module Hello # PASS
          HELLO
        end

        module Hello2 # PASS
          # ANOTHER PASS
          def x; end
        end
      eof

      Registry.at(:Hello).docstring.should == "PASS"
      Registry.at(:Hello2).docstring.should == "PASS"
      Registry.at('Hello2#x').docstring.should == "ANOTHER PASS"
    end
    
    it "should take preceeding comments only if they exist" do
      YARD.parse_string <<-eof
        # PASS
        module Hello # FAIL
          HELLO
        end
      eof

      Registry.at(:Hello).docstring.should == "PASS"
    end
    
    it "should handle =begin/=end style comments" do
      YARD.parse_string "=begin\nfoo\nbar\n=end\nclass Foo; end\n"
      Registry.at(:Foo).docstring.should == "foo\nbar"

      YARD.parse_string "=begin\n\nfoo\nbar\n=end\nclass Foo; end\n"
      Registry.at(:Foo).docstring.should == "foo\nbar"

      YARD.parse_string "=begin\nfoo\n\nbar\n=end\nclass Foo; end\n"
      Registry.at(:Foo).docstring.should == "foo\n\nbar"
    end
  end

  describe '#parse' do
    it "should parse a basic Ruby file" do
      parse_file :example1, __FILE__
      Registry.at(:Hello).should_not == nil
      Registry.at("Hello::Hi#me").should_not == nil
      Registry.at("Hello::Hi#me").docstring.should == "Docstring"
    end
  
    it "should parse a set of file globs" do
      Dir.should_receive(:[]).with('lib/**/*.rb').and_return([])
      YARD.parse('lib/**/*.rb')
    end
  
    it "should parse a set of absolute paths" do
      Dir.should_not_receive(:[]).and_return([])
      File.should_receive(:file?).with('/path/to/file').and_return(true)
      File.should_receive(:read_binary).with('/path/to/file').and_return("")
      YARD.parse('/path/to/file')
    end
    
    it "should clean paths before parsing" do
      File.should_receive(:open).and_return("")
      parser = Parser::SourceParser.new(:ruby, true)
      parser.parse('a//b//c')
      parser.file.should == 'a/b/c'
    end

    it "should parse files with '*' in them as globs and others as absolute paths" do
      Dir.should_receive(:[]).with('*.rb').and_return(['a.rb', 'b.rb'])
      File.should_receive(:file?).with('/path/to/file').and_return(true)
      File.should_receive(:file?).with('a.rb').and_return(true)
      File.should_receive(:file?).with('b.rb').and_return(true)
      File.should_receive(:read_binary).with('/path/to/file').and_return("")
      File.should_receive(:read_binary).with('a.rb').and_return("")
      File.should_receive(:read_binary).with('b.rb').and_return("")
      YARD.parse ['/path/to/file', '*.rb']
    end
    
    it "should convert directories into globs" do
      Dir.should_receive(:[]).with('foo/**/*.{rb,c}').and_return(['foo/a.rb', 'foo/bar/b.rb'])
      File.should_receive(:directory?).with('foo').and_return(true)
      File.should_receive(:file?).with('foo/a.rb').and_return(true)
      File.should_receive(:file?).with('foo/bar/b.rb').and_return(true)
      File.should_receive(:read_binary).with('foo/a.rb').and_return("")
      File.should_receive(:read_binary).with('foo/bar/b.rb').and_return("")
      YARD.parse ['foo']
    end
    
    it "should use Registry.checksums cache if file is cached" do
      data = 'DATA'
      hash = Registry.checksum_for(data)
      cmock = mock(:cmock)
      cmock.should_receive(:[]).with('foo/bar').and_return(hash)
      Registry.should_receive(:checksums).and_return(cmock)
      File.should_receive(:file?).with('foo/bar').and_return(true)
      File.should_receive(:read_binary).with('foo/bar').and_return(data)
      YARD.parse('foo/bar')
    end
    
    it "should support excluded paths" do
      File.should_receive(:file?).with('foo/bar').and_return(true)
      File.should_receive(:file?).with('foo/baz').and_return(true)
      File.should_not_receive(:read_binary)
      YARD.parse(["foo/bar", "foo/baz"], ["foo", /baz$/])
    end
  end
  
  describe '#parse_in_order' do
    def in_order_parse(*files)
      paths = files.map {|f| File.join(File.dirname(__FILE__), 'examples', f.to_s + '.rb.txt') }
      YARD::Parser::SourceParser.parse(paths, [], Logger::DEBUG)
    end
    
    it "should attempt to parse files in order" do
      msgs = []
      log.should_receive(:debug) {|m| msgs << m }.at_least(:once)
      in_order_parse 'parse_in_order_001', 'parse_in_order_002'
      msgs[1].should =~ /Processing .+parse_in_order_001.+/
      msgs[2].should =~ /Missing object MyModule/
      msgs[3].should =~ /Processing .+parse_in_order_002.+/
      msgs[4].should =~ /Re-processing .+parse_in_order_001.+/
    end
    
    it "should attempt to order files by length (process toplevel files first)" do
      %w(a a/b a/b/c).each do |file|
        File.should_receive(:file?).with(file).and_return(true)
        File.should_receive(:read_binary).with(file).ordered.and_return('')
      end
      YARD.parse %w(a/b/c a/b a)
    end
  end
  
  describe '#parse_statements' do
    it "should display a warning for invalid parser type" do
      log.should_receive(:warn).with(/unrecognized file/)
      YARD::Parser::SourceParser.parse_string("int main() { }", :d)
    end
    
    if RUBY19
      it "should display a warning for a syntax error (with new parser)" do
        err_msg = "Syntax error in `(stdin)`:(1,3): syntax error, unexpected $undefined, expecting $end"
        log.should_receive(:warn).with(err_msg)
        YARD::Parser::SourceParser.parse_string("$$$", :ruby)
      end
    end
  end
end