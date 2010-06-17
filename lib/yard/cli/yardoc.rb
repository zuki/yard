require 'digest/sha1'
require 'fileutils'

module YARD
  module CLI
    class Yardoc < Command
      # The configuration filename to load extra options from
      DEFAULT_YARDOPTS_FILE = ".yardopts"
      
      # @return [Hash] the hash of options passed to the template.
      # @see Templates::Engine#render
      attr_reader :options
      
      # @return [Array<String>] list of Ruby source files to process
      attr_accessor :files
      
      # @return [Array<String>] list of excluded paths (regexp matches)
      attr_accessor :excluded
      
      # @return [Boolean] whether to use the existing yardoc db if the 
      #   .yardoc already exists. Also makes use of file checksums to
      #   parse only changed files.
      attr_accessor :use_cache
      
      # @return [Boolean] whether to generate output incrementally (
      #   implies use_cache and generate)
      attr_accessor :incremental
      
      # @return [Boolean] whether to generate output
      attr_accessor :generate

      # @return [Boolean] whether to print a list of objects
      attr_accessor :list

      # The options file name (defaults to {DEFAULT_YARDOPTS_FILE})
      # @return [String] the filename to load extra options from
      attr_accessor :options_file
      
      # Keep track of which visibilities are to be shown
      # @return [Array<Symbol>] a list of visibilities
      attr_accessor :visibilities
      
      # @return [Boolean] whether to build or rebuild gems
      attr_accessor :build_gems, :rebuild_gems
      
      # Helper method to create an instance and run the utility
      # @see #run
      def self.run(*args) new.run(*args) end
        
      # Creates a new instance of the commandline utility
      def initialize
        super
        @options = SymbolHash.new(false)
        @options.update(
          :format => :html, 
          :template => :default, 
          :markup => :rdoc,
          :serializer => YARD::Serializers::FileSystemSerializer.new,
          :default_return => "Object",
          :hide_void_return => false,
          :no_highlight => false, 
          :files => [],
          :verifier => Verifier.new
        )
        @visibilities = [:public]
        @excluded = []
        @files = []
        @use_cache = false
        @build_gems = false
        @rebuild_gems = false
        @generate = true
        @incremental = false
        @options_file = DEFAULT_YARDOPTS_FILE
      end
      
      def description
        "Generates documentation"
      end
    
      # Runs the commandline utility, parsing arguments and generating
      # output if set.
      # 
      # @param [Array<String>] args the list of arguments
      # @return [void] 
      def run(*args)
        parse_arguments(*args)
        
        if use_cache
          Registry.load
          checksums = Registry.checksums.dup
        end
        YARD.parse(files, excluded)
        Registry.save(use_cache)
        
        
        if build_gems
          do_build_gems(rebuild_gems)
        elsif generate
          if incremental
            generate_with_cache(checksums)
          else
            Registry.load_all if use_cache
            Templates::Engine.generate(all_objects, options)
          end
        elsif list
          print_list
        end
        
        true
      end
      
      # Parses commandline arguments
      # @param [Array<String>] args the list of arguments
      # @return [void]
      def parse_arguments(*args)
        optparse(*support_rdoc_document_file!)
        optparse(*yardopts)
        optparse(*args)

        # Last minute modifications
        self.files = ['lib/**/*.rb', 'ext/**/*.c'] if self.files.empty?
        self.files.delete_if {|x| x =~ /\A\s*\Z/ } # remove empty ones
        options[:readme] ||= Dir.glob('README*').first
        if options[:onefile]
          options[:files] << options[:readme] if options[:readme]
          options[:readme] = Dir.glob(files.first).first 
        end
        add_visibility_verifier
      end
      
      # The list of all objects to process. Override this method to change
      # which objects YARD should generate documentation for.
      # 
      # @return [Array<CodeObjects::Base>] a list of code objects to process
      def all_objects
        Registry.all(:root, :module, :class)
      end
      
      # Parses the .yardopts file for default yard options
      # @return [void] 
      def yardopts
        File.read_binary(options_file).shell_split
      rescue Errno::ENOENT
        []
      end
      
      private
      
      # Generates output for changed objects in cache
      # @return [void]
      def generate_with_cache(checksums)
        changed_files = []
        Registry.checksums.each do |file, hash|
          changed_files << file if checksums[file] != hash
        end
        Registry.load_all
        all_objects.each do |object|
          if object.files.any? {|f, line| changed_files.include?(f) }
            log.info "Re-generating object #{object.path}..."
            opts = options.merge(:object => object, :type => :layout)
            Templates::Engine.render(opts)
          end
        end
      end

      # Prints a list of all objects
      # @return [void]
      def print_list
        Registry.load_all
        Registry.all.
          reject {|item| options[:verifier].call(item).is_a?(FalseClass) }.
          sort_by {|item| [item.file, item.line]}.each do |item|
          puts "#{item.file}:#{item.line}: #{item}"
        end
      end

      # Reads a .document file in the directory to get source file globs
      # @return [void] 
      def support_rdoc_document_file!
        IO.read(".document").gsub(/^[ \t]*#.+/m, '').split(/\s+/)
      rescue Errno::ENOENT
        []
      end
      
      # Adds a set of extra documentation files to be processed
      # @param [Array<String>] files the set of documentation files
      def add_extra_files(*files)
        files.map! {|f| f.include?("*") ? Dir.glob(f) : f }.flatten!
        files.each do |file|
          if File.file?(file)
            options[:files] << file
          else
            log.warn "Could not find extra file: #{file}"
          end
        end
      end
      
      # Parses the file arguments into Ruby files and extra files, which are
      # separated by a '-' element.
      # 
      # @example Parses a set of Ruby source files
      #   parse_files %w(file1 file2 file3)
      # @example Parses a set of Ruby files with a separator and extra files
      #   parse_files %w(file1 file2 - extrafile1 extrafile2)
      # @param [Array<String>] files the list of files to parse
      # @return [void] 
      def parse_files(*files)
        seen_extra_files_marker = false
        
        files.each do |file|
          if file == "-"
            seen_extra_files_marker = true
            next
          end
          
          if seen_extra_files_marker
            add_extra_files(file)
          else
            self.files << file
          end
        end
      end
      
      # Builds .yardoc files for all non-existing gems
      # @param [Boolean] rebuild Forces rebuild of all gems
      def do_build_gems(rebuild = false)
        require 'rubygems'
        Gem.source_index.find_name('').each do |spec|
          reload = true
          dir = Registry.yardoc_file_for_gem(spec.name)
          if dir && File.directory?(dir) && !rebuild
            log.debug "#{spec.name} index already exists at '#{dir}'"
          else
            yfile = Registry.yardoc_file_for_gem(spec.name, ">= 0", true)
            next unless yfile
            Registry.clear
            Dir.chdir(spec.full_gem_path)
            log.info "Building yardoc index for gem: #{spec.full_name}"
            Yardoc.run('-n', '-b', yfile)
            reload = false
          end
        end
        exit(0)
      end
      
      # Adds verifier rule for visibilities
      # @return [void]
      def add_visibility_verifier
        vis_expr = "object.type != :method || #{visibilities.uniq.inspect}.include?(object.visibility)"
        options[:verifier].add_expressions(vis_expr)
      end
      
      # Parses commandline options.
      # @param [Array<String>] args each tokenized argument
      def optparse(*args)
        opts = OptionParser.new
        opts.banner = "Usage: yardoc [options] [source_files [- extra_files]]"

        opts.separator "(if a list of source files is omitted, lib/**/*.rb ext/**/*.c is used.)"
        opts.separator ""
        opts.separator "Example: yardoc -o documentation/ - FAQ LICENSE"
        opts.separator "  The above example outputs documentation for files in"
        opts.separator "  lib/**/*.rb to documentation/ including the extra files"
        opts.separator "  FAQ and LICENSE."
        opts.separator ""
        opts.separator "A base set of options can be specified by adding a .yardopts"
        opts.separator "file to your base path containing all extra options separated"
        opts.separator "by whitespace."
        opts.separator ""
        opts.separator "General Options:"

        opts.on('-c', '--use-cache [FILE]', 
                "Use the cached .yardoc db to generate documentation. (defaults to no cache)") do |file|
          YARD::Registry.yardoc_file = file if file
          self.use_cache = true
        end
        
        opts.on('-b', '--db FILE', 'Use a specified .yardoc db to load from or save to. (defaults to .yardoc)') do |yfile|
          YARD::Registry.yardoc_file = yfile
        end
        
        opts.on('-n', '--no-output', 'Only generate .yardoc database, no documentation.') do
          self.generate = false
        end
        
        opts.on('-e', '--load FILE', 'A Ruby script to load before the source tree is parsed.') do |file|
          if !require(file.gsub(/\.rb$/, ''))
            log.error "The file `#{file}' was already loaded, perhaps you need to specify the absolute path to avoid name collisions."
            exit
          end
        end
        
        opts.on('--one-file', 'Generates output as a single file') do
          options[:onefile] = true
        end
        
        opts.on('--incremental', 'Generates output for changed files only (implies -c)') do
          self.incremental = true
          self.generate = true
          self.use_cache = true
        end
        
        opts.on('--exclude REGEXP', 'Ignores a file if it matches path match (regexp)') do |path|
          self.excluded << path
        end
        
        opts.on('--legacy', 'Use old style parser and handlers. Unavailable under Ruby 1.8.x') do
          YARD::Parser::SourceParser.parser_type = :ruby18
        end
        
        opts.on('--build-gems', 'Builds .yardoc files for all gems (implies -n)') do
          self.build_gems = true
        end

        opts.on('--re-build-gems', 'Forces building .yardoc files for all gems (implies -n)') do
          self.build_gems = true
          self.rebuild_gems = true
        end

        opts.separator ""
        opts.separator "Output options:"
  
        opts.on('--no-public', "Don't show public methods. (default shows public)") do 
          visibilities.delete(:public)
        end

        opts.on('--protected', "Show or don't show protected methods. (default hides protected)") do
          visibilities.push(:protected)
        end

        opts.on('--private', "Show or don't show private methods. (default hides private)") do 
          visibilities.push(:private)
        end
        
        opts.on('--no-private', "Hide objects with @private tag") do
          options[:verifier].add_expressions '!object.tag(:private) && !object.namespace.tag(:private)'
        end

        opts.on('--no-highlight', "Don't highlight code in docs as Ruby.") do 
          options[:no_highlight] = true
        end
        
        opts.on('--default-return TYPE', "Shown if method has no return type. Defaults to 'Object'") do |type|
          options[:default_return] = type
        end
        
        opts.on('--hide-void-return', "Hides return types specified as 'void'. Default is shown.") do
          options[:hide_void_return] = true
        end
        
        opts.on('--query QUERY', "Only show objects that match a specific query") do |query|
          options[:verifier].add_expressions(query.taint)
        end

        opts.on('--list', 'List objects to standard out (implies -n)') do |format|
          self.generate = false
          self.list = true
        end

        opts.on('--title TITLE', 'Add a specific title to HTML documents') do |title|
          options[:title] = title
        end

        opts.on('-r', '--readme FILE', '--main FILE', 'The readme file used as the title page of documentation.') do |readme|
          if File.file?(readme)
            options[:readme] = readme
          else 
            log.warn "Could not find readme file: #{readme}"
          end
        end
        
        opts.on('--files FILE1,FILE2,...', 'Any extra comma separated static files to be included (eg. FAQ)') do |files|
          add_extra_files(*files.split(","))
        end

        opts.on('-m', '--markup MARKUP', 
                'Markup style used in documentation, like textile, markdown or rdoc. (defaults to rdoc)') do |markup|
          options[:markup] = markup.to_sym
        end

        opts.on('-M', '--markup-provider MARKUP_PROVIDER', 
                'Overrides the library used to process markup formatting (specify the gem name)') do |markup_provider|
          options[:markup_provider] = markup_provider.to_sym
        end
        
        opts.on('-o', '--output-dir PATH', 
                'The output directory. (defaults to ./doc)') do |dir|
          options[:serializer].basepath = dir
        end
        
        opts.on('--charset ENC', 'Character set to use for HTML output (default is system locale)') do |encoding|
          begin
            Encoding.default_external = encoding
          rescue ArgumentError => e
            raise OptionParser::InvalidOption, e
          end
        end

        opts.on('-t', '--template TEMPLATE', 
                'The template to use. (defaults to "default")') do |template|
          options[:template] = template.to_sym
        end

        opts.on('-p', '--template-path PATH', 
                'The template path to look for templates in. (used with -t).') do |path|
          YARD::Templates::Engine.register_template_path(path)
        end
        
        opts.on('-f', '--format FORMAT', 
                'The output format for the template. (defaults to html)') do |format|
          options[:format] = format.to_sym
        end

        common_options(opts)
        parse_options(opts, args)
        parse_files(*args) unless args.empty?
      end
    end
  end
end
