require 'optparse'
require 'zlib'
require 'json'
require 'time'
require 'pp'

class ChkBuildRubyInfo
  DefaultOption = {
    :type => nil,
    :enable_sole_record => true,
  }.freeze

  DefaultOption.each {|k, v|
    define_method("opt_#{k}") { @opts[k] }
    define_method("opt_#{k}=") {|v| @opts[k] = v }
  }

  def initialize(f, opts=DefaultOption.dup)
    @f = f
    @unique_hash = {}
    @last_hash = {"type"=>"build"}
    @json_array_first = nil
    @common_hash = nil

    @current_section_name = nil
    @current_section_start_time = nil
    @output_proc = nil
    @out = $stdout

    @opts = opts;
  end

  attr_reader :common_hash
  def common_hash=(hash)
    h = {}
    hash.each {|k, v|
      h[k.to_s]= v
    }
    @common_hash = h
  end

  def with_output_proc(callable)
    save = @output_proc
    @output_proc = callable
    begin
      yield
    ensure
      @output_proc = save
    end
  end

  def output_json_outermost_array
    @json_array_first = true
    yield
    if @json_array_first
      @out.print "[]\n"
    else
      @out.print "\n]\n"
    end
  end

  def output_json_object(hash)
    if @opts.fetch(:type)
      unless @opts.fetch(:type).include? hash["type"]
        return
      end
    end
    if @json_array_first
      @out.print "[\n"
      @json_array_first = false
    else
      @out.print ",\n"
    end
    @out.print JSON.dump(hash)
  end

  def output_unique_hash(hash)
    return unless @opts.fetch(:enable_sole_record)
    hash = hash.dup.freeze
    if !@unique_hash.has_key?(hash)
      output_hash(hash)
      @unique_hash[hash] = true
    end
  end

  def path_after_time(str)
    if %r{/\d{8,}T\d{6}Z/} =~ str
      $'
    else
      str
    end
  end

  def output_hash(hash)
    if  /\A[a-z0-9_]+\z/ !~ hash['type']
      warn "unexpected type name: #{hash['type']}"
    end
    hash.each {|k, v|
      if /\A[a-z0-9_]+\z/ !~ k
        warn "unexpected field name: #{k.inspect}"
      end
    }
    @output_proc.call hash
  end

  def output_sole_hash(hash)
    return unless @opts.fetch(:enable_sole_record)
    output_hash(hash)
  end

  def update_last_hash(hash, prefix=nil)
    hash.each {|k, v|
      next if k == 'type'
      k = "#{prefix}_#{k}" if prefix
      if @last_hash.has_key?(k) && v != @last_hash[k]
        warn "last hash not updated: #{k.inspect} : #{@last_hash[k].inspect} v.s. #{hash[k].inspect}"
        next
      end
      @last_hash[k] = v
    }
  end

  def gsub_path_to_time(str)
    str.gsub(%r{/\S+/\d{8,}T\d{6}Z/}, '')
  end

  def strip_colon(str)
    str.gsub(/\A:|:\z/, '')
  end

  def scan_section_start(secname, rest)
    if /\d{4,}-\d\d-\d\dT\d\d:\d\d:\d\d[+-]\d\d:\d\d/ =~ rest
      t = $&
    end

    if @current_section_name
      h = { "type" => "section_end", "secname" => @current_section_name }
      h["end_time"] = t if t
      if t && @current_section_start_time
        h["elapsed"] = Time.iso8601(t) - Time.iso8601(@current_section_start_time)
      end
      output_hash h
    end

    h = { "type" => "section_start", "secname" => secname }
    h["start_time"] = t if t
    output_hash h

    @current_section_name = secname
    @current_section_start_time = t
  end

  def scan_first_section(secname, section)
    #== ruby-trunk # 2014-05-24T22:36:01+09:00
    h = { "type" => "depsuffixed_name", "depsuffixed_name" => secname }
    output_sole_hash h
    update_last_hash(h)

    suffixed_name = secname[/\A[^_]+/]
    h = { "type" => "suffixed_name", "suffixed_name" => suffixed_name }
    output_sole_hash h
    update_last_hash(h)

    target_name = suffixed_name[/\A[^-]+/]
    h = { "type" => "target_name", "target_name" => target_name }
    output_sole_hash h
    update_last_hash(h)

    #Nickname: boron
    if /^Nickname: (\S+)/ =~ section
      h = {"type"=>"nickname", "nickname"=>$1 }
      output_sole_hash(h)
      update_last_hash(h)
    end

    uname = { "type" => "uname" }
    uname["sysname"] = $1 if /^uname_s: (.+)$/ =~ section
    uname["release"] = $1 if /^uname_r: (.+)$/ =~ section
    uname["version"] = $1 if /^uname_v: (.+)$/ =~ section
    uname["machine"] = $1 if /^uname_m: (.+)$/ =~ section
    uname["processor"] = $1 if /^uname_p: (.+)$/ =~ section
    uname["hardware_platform"] = $1 if /^uname_i: (.+)$/ =~ section
    uname["operating_system"] = $1 if /^uname_o: (.+)$/ =~ section
    if 1 < uname.size
      output_sole_hash(uname)
      update_last_hash(uname, 'uname')
    end

    debian = { "type" => "debian" }
    debian["version"] = $1 if /^debian_version: (\S+)$/ =~ section
    debian["architecture"] = $1 if /^Debian Architecture: (\S+)$/ =~ section
    if 1 < debian.size
      output_sole_hash(debian)
      update_last_hash(debian, 'debian')
    end

    lsb = { "type" => "lsb" } # lsb_release
    lsb["distributor"] = $1 if /^Distributor ID:\s*(\S+)$/ =~ section
    lsb["description"] = $1 if /^Description:\s*(\S+)$/ =~ section
    lsb["release"] = $1 if /^Release:\s*(\S+)$/ =~ section
    lsb["codename"] = $1 if /^Codename:\s*(\S+)$/ =~ section
    if 1 < lsb.size
      output_sole_hash(lsb)
      update_last_hash(lsb, 'lsb')
    end
  end

  def scan_start(section)
    if /^start-time: (\S+)/ =~ section
      h = {"type"=>"start_time", "start_time"=>$1 }
      output_unique_hash(h)
      update_last_hash(h)
    end

    if /^build-dir: (\S+)/ =~ section
      h = {"type"=>"build_dir", "dir"=>$1 }
      output_unique_hash(h)
      update_last_hash(h, 'build')
    end
  end

  def scan_autoconf_version(section)
    #autoconf (GNU Autoconf) 2.67
    if /^autoconf \(GNU Autoconf\) (\S+)/ =~ section
      h = {"type"=>"autoconf_version", "version"=>$1 }
      output_sole_hash(h)
      update_last_hash(h, 'autoconf')
    end
  end

  def scan_bison_version(section)
    #bison (GNU Bison) 2.4.1
    if /^bison \(GNU Bison\) (\S+)/ =~ section
      h = {"type"=>"bison_version", "version"=>$1 }
      output_sole_hash(h)
      update_last_hash(h, 'bison')
    end
  end

  def scan_version_h(section)
    ##define RUBY_VERSION "2.2.0"
    ##define RUBY_RELEASE_DATE "2014-05-24"
    ##define RUBY_PATCHLEVEL -1
    ##define RUBY_BRANCH_NAME "trunk"
    ##define RUBY_RELEASE_YEAR 2014
    ##define RUBY_RELEASE_MONTH 5
    ##define RUBY_RELEASE_DAY 24
    h = { "type" => "ruby_release" }
    h["version"] = $1 if /^\#define RUBY_VERSION "(\S+)"/ =~ section
    h["release_date"] = $1 if /^\#define RUBY_RELEASE_DATE "(\S+)"/ =~ section
    h["patchlevel"] = $1.to_i if /^\#define RUBY_PATCHLEVEL (\S+)/ =~ section
    h["branch_name"] = $1 if /^\#define RUBY_BRANCH_NAME "(\S+)"/ =~ section
    h["release_year"] = $1.to_i if /^\#define RUBY_RELEASE_YEAR (\S+)/ =~ section
    h["release_month"] = $1.to_i if /^\#define RUBY_RELEASE_MONTH (\S+)/ =~ section
    h["release_day"] = $1.to_i if /^\#define RUBY_RELEASE_DAY (\S+)/ =~ section
    if 1 < h.size
      output_sole_hash(h)
      h1 = h.reject {|k, v| /\Arelease_/ =~ k }
      h2 = h.reject {|k, v| /\Arelease_/ !~ k }
      update_last_hash(h1, 'ruby_release')
      update_last_hash(h2, 'ruby')
    end
  end

  def scan_configure(section)
    if %r{^\+ \S+/configure --prefix=(\S+/([0-9]{8,}T[0-9]{6}Z?))(?: |$)} =~ section
      h = {"type"=>"start_time", "start_time"=>$2 }
      output_unique_hash(h)
      update_last_hash(h)
      h = {"type"=>"build_dir", "dir"=>$1 }
      output_unique_hash(h)
      update_last_hash(h, 'build')
    end
  end

  def scan_verconf_h(section)
    ##define RUBY_PLATFORM "i686-linux"
    if /^\#define RUBY_PLATFORM "(\S+)"/ =~ section
      h = {"type"=>"ruby_platform", "platform"=>$1 }
      output_sole_hash(h)
      update_last_hash(h, 'ruby')
    end
  end

  def scan_config_files(section)
    #config.guess: 2014-03-23
    #config.sub: 2014-05-01
    h = { "type" => "config_files" }
    h["config_guess"] = $1 if /^config\.guess: (\S+)/ =~ section
    h["config_sub"] = $1 if /^config\.sub: (\S+)/ =~ section
    if 1 < h.size
      output_sole_hash(h)
      update_last_hash(h)
    end
  end

  def scan_cc_version(section)
    #gcc (GCC) 4.8.0
    if /^gcc \(GCC\) (\S+)/ =~ section
      h = {"type"=>"cc_version", "cc"=>"gcc", "version"=>$1 }
      output_sole_hash(h)
      update_last_hash({ "cc"=>"gcc", "cc_version"=>h["version"] })
    end
  end

  def scan_miniruby_libc(section)
    #GNU C Library (Debian EGLIBC 2.11.3-4) stable release version 2.11.3, by Roland McGrath et al.
    if /^(GNU C Library .*), by/ =~ section
      h = {"type"=>"libc_version", "version"=>$1 }
      output_sole_hash(h)
      update_last_hash(h, 'libc')
    end
  end

  def scan_svn(section)
    # chkbuild run "svn info" since 2009-12-16.
    url = /^Repository Root: (\S+)$/.match(section)
    lastrev = /^Last Changed Rev: (\d+)$/.match(section)
    if url && lastrev
      h = {
        "type" => "svn",
        "url" => url[1],
        "rev" => lastrev[1].to_i
      }
      output_hash h
      if h["url"] == "http://svn.ruby-lang.org/repos/ruby"
        update_last_hash({ "ruby_rev" => h["rev"] })
      end
    end
  end

  def scan_svn_old_chkbuild(section)
    # chkbuild didn't run "svn info" but recorded CHG line between 2007-11-01 and 2009-12-16.
    #
    #+ svn checkout -q http://svn.ruby-lang.org/repos/ruby/trunk ruby
    #CHG .   26102->26106    http://svn.ruby-lang.org/cgi-bin/viewvc.cgi?view=rev&revision=26106;diff_format=u
    url = /^\+ svn checkout -q (\S*)/.match(section)
    lastrev = /^CHG \.\t\d+->(\d+)/.match(section)
    if url && lastrev
      h = {
        "type" => "svn",
        "url" => url[1],
        "rev" => lastrev[1].to_i
      }
      output_hash h
      if h["url"] == "http://svn.ruby-lang.org/repos/ruby"
        update_last_hash({ "ruby_rev" => h["rev"] })
      end
    end
  end

  def scan_git(section)
    #CHECKOUT git git://github.com/nurse/mspec.git mspec
    #LASTCOMMIT 88ffc944daaa9f1894521f8abaddc88d9a087342
    url = /^CHECKOUT git (\S+)/.match(section)
    commit = /^LASTCOMMIT (\S+)$/.match(section)
    if url && commit
      h = {
        "type" => "git",
        "url" => url[1],
        "commit" => commit[1]
      }
      output_hash h
      case h["url"]
      when "git://github.com/nurse/mspec.git", "git://github.com/rubyspec/mspec.git"
        update_last_hash({ "mspec_commit" => h["commit"] })
      when "git://github.com/nurse/rubyspec.git", "git://github.com/rubyspec/rubyspec.git"
        update_last_hash({ "rubyspec_commit" => h["commit"] })
      end
    end
  end

  def scan_method_list(section)
    #class ARGF.class [Enumerable, Object, Kernel, BasicObject]
    #ARGF.class#argv 0
    #ARGF.class#each -1
    #Array.[] -1
    #Array#<< 1
    #File.lchmod 0 not-implemented
    #module Comparable []
    #class fatal [Exception, Object, Kernel, BasicObject]
    #
    #Old format:
    #ARGF.class [Enumerable, Object, Kernel, BasicObject]
    section.each_line {|line|
      case line
      when /\A(?:(module|class) )?(\S+) \[(.*)\]\n/
        module_or_class = $1
        h = {
          'type' => 'builtin_module',
          'module' => $2,
          'ancestors' => $3.split(/,\s*/)
        }
        if module_or_class
          h['class'] = module_or_class == 'class'
        end
        output_hash h
      when /\A(\S+)\#(\S+) (-?\d+)( not-implemented)?\n/
        h = {
          'type' => 'builtin_instance_method',
          'class' => $1,
          'method' => $2,
          'arity' => $3.to_i,
          'implemented' => $4 ? false : true
        }
        output_hash h
      when /\A(\S+)\.(\S+) (-?\d+)( not-implemented)?\n/
        h = {
          'type' => 'builtin_class_method',
          'class' => $1,
          'method' => $2,
          'arity' => $3.to_i,
          'implemented' => $4 ? false : true
        }
        output_hash h
      end
    }
  end

  def scan_showflags(section)
    h = { 'type' => 'make_flags' }
    h["cc"] = $1.strip if /^[ \t]+CC = (.+)\n/ =~ section
    h["ld"] = $1.strip if /^[ \t]+LD = (.+)\n/ =~ section
    h["ldshared"] = $1.strip if /^[ \t]+LDSHARED = (.+)\n/ =~ section
    h["cflags"] = $1.strip if /^[ \t]+CFLAGS = (.+)\n/ =~ section
    h["xcflags"] = $1.strip if /^[ \t]+XCFLAGS = (.+)\n/ =~ section
    h["cppflags"] = $1.strip if /^[ \t]+CPPFLAGS = (.+)\n/ =~ section
    h["dldflags"] = $1.strip if /^[ \t]+DLDFLAGS = (.+)\n/ =~ section
    h["solibs"] = $1.strip if /^[ \t]+SOLIBS = (.+)\n/ =~ section
    h["target"] = $1.strip if /^Target: (.+)\n/ =~ section
    output_sole_hash h
    update_last_hash(h, 'make_flag')
  end

  def scan_ruby_v(section)
    #ruby 2.2.0dev (2014-05-24 trunk 46082) [i686-linux]
    if /^ruby .*/ =~ section
      h = {"type"=>"ruby_version", "version"=>$& }
      output_sole_hash(h)
      update_last_hash(h, 'ruby')
    end
  end

  def scan_version_list(section)
    %w[
      libc
      gmp
      dbm
      gdbm
      readline
      openssl
      zlib
      tcltklib
      curses
    ].each {|lib|
      if /^#{Regexp.escape lib}: (.*)\n/ =~ section
        h = { 'type' => "ruby_lib_version", "lib" => lib, "version" => $1 }
        output_sole_hash h
        update_last_hash({ "used_#{lib}_version" => h["version"] })
      end
    }
  end

  def scan_abi_check(section)
    high = 0
    section.scan(/ High +([0-9])+ *$/) { high += $1.to_i }
    medium = 0
    section.scan(/ Medium +([0-9])+ *$/) { medium += $1.to_i }
    low = 0
    section.scan(/ Low +([0-9])+ *$/) { low += $1.to_i }
    h = {
      'type' => "abi_check_summary",
      "high" => high,
      "medium" => medium,
      "low" => low
    }
    output_sole_hash h
    update_last_hash(h, 'abi_check_summary')
  end

  BTEST_RESULT_MAP = {
    '.' => 'success',
    'F' => 'failure',
  }
  def scan_btest(secname, section)
    #test_io.rb
    ##257 test_io.rb:1 .
    ##258 test_io.rb:11 .
    ##259 test_io.rb:34 .
    ##260 test_io.rb:44 F
    #stderr output is not empty
    #   /extdisk/chkbuild/chkbuild/tmp/build/20140424T124800Z/ruby/lib/tmpdir.rb:8:in `require': cannot load such file -- etc.so (LoadError)
    #           from /extdisk/chkbuild/chkbuild/tmp/build/20140424T124800Z/ruby/lib/tmpdir.rb:8:in `<top (required)>'
    #           from bootstraptest.tmp.rb:2:in `require'
    #           from bootstraptest.tmp.rb:2:in `<main>'
    ##261 test_io.rb:60 F
    #stderr output is not empty
    #   /extdisk/chkbuild/chkbuild/tmp/build/20140424T124800Z/ruby/lib/tmpdir.rb:8:in `require': cannot load such file -- etc.so (LoadError)
    #           from /extdisk/chkbuild/chkbuild/tmp/build/20140424T124800Z/ruby/lib/tmpdir.rb:8:in `<top (required)>'
    #           from bootstraptest.tmp.rb:2:in `require'
    #           from bootstraptest.tmp.rb:2:in `<main>'
    ##262 test_io.rb:77 .
    ##263 test_io.rb:85 .
    ##264 test_io.rb:105 .
    ##265 test_io.rb:112 .

    #KNOWNBUGS.rb #1 KNOWNBUGS.rb:16:in `<top (required)>'
    #F

    section.scan(/\#(\d+) (\S+):(\d+)(.*)\s([.F])$/) {
      h = {
        "type" => "btest_result",
        "test_suite" => secname,
        "testnum" => $1.to_i,
        "file" => $2,
        "line" => $3.to_i,
        "caller" => strip_colon($4),
        "result" => BTEST_RESULT_MAP.fetch($5, $5)
      }
      output_hash h
    }

    ##260 test_io.rb:44:
    #     require 'tmpdir'
    #     begin
    #       tmpname = "#{Dir.tmpdir}/ruby-btest-#{$$}-#{rand(0x100000000).to_s(36)}"
    #       rw = File.open(tmpname, File::RDWR|File::CREAT|File::EXCL)
    #     rescue Errno::EEXIST
    #       retry
    #     end
    #     save = STDIN.dup
    #     STDIN.reopen(rw)
    #     STDIN.reopen(save)
    #     rw.close
    #     File.unlink(tmpname) unless RUBY_PLATFORM['nacl']
    #     :ok
    #  #=> "" (expected "ok")

    ##1 KNOWNBUGS.rb:16:in `<top (required)>': 
    #     open("tst-remove-load.rb", "w") {|f|
    #       f << <<-'End'
    #         module Kernel
    #           remove_method :load
    #         end
    #         raise
    #       End
    #     }
    #     load "tst-remove-load.rb"
    #  #=> killed by SIGSEGV (signal 11)
    #| tst-remove-load.rb:4: [BUG] Segmentation fault
    #| ruby 1.9.2dev (2010-02-20 trunk 26717) [i686-linux]
    #| 
    #| -- control frame ----------
    #| c:0006 p:0019 s:0015 b:0015 l:000014 d:000014 TOP    tst-remove-load.rb:4
    #| c:0005 p:---- s:0013 b:0013 l:000012 d:000012 FINISH
    #  [ruby-dev:40234] [ruby-core:27959]
    #FAIL 1/1 tests failed

    section.scan(/^\#(\d+) (\S+):(\d+):(.*) \n((?: {5}.*\n)*)  \#=> (.*)/) {
      h = {
        "type" => "btest_detail",
        "test_suite" => secname,
        "testnum" => $1.to_i,
        "file" => $2,
        "line" => $3.to_i,
        "caller" => strip_colon($4),
        "code" => $5,
        "message" => $6,
      }
      output_hash h
    }

    h = nil
    if /^No tests, no problem$/ =~ section
      h = {
        "type" => "btest_summary",
        "test_suite" => secname,
        "tests" => 0,
        "failures" => 0
      }
    elsif /^PASS all (\d+) tests/ =~ section
      h = {
        "type" => "btest_summary",
        "test_suite" => secname,
        "tests" => $1.to_i,
        "failures" => 0
      }
    elsif /^FAIL (\d+)\/(\d+) tests failed/ =~ section
      h = {
        "type" => "btest_summary",
        "test_suite" => secname,
        "tests" => $2.to_i,
        "failures" => $1.to_i,
      }
    end
    if h
      output_hash h
      h.delete 'test_suite'
      case secname
      when 'btest'
        update_last_hash(h, 'btest')
      when 'test-knownbug'
        update_last_hash(h, 'knownbug')
      end
    end
  end

  def scan_testrb(section)
    #sample/test.rb:assignment .ok 1 (sample/test.rb:129:in `<main>')
    #.ok 2 (sample/test.rb:131:in `<main>')
    #.ok 3 (sample/test.rb:135:in `<main>')
    #.ok 4 (sample/test.rb:137:in `<main>')

    #.ok 59 (sample/test.rb:1719:in `<main>')
    #.ok 60 (sample/test.rb:1720:in `<main>')
    #Fnot ok string & char 61 -- sample/test.rb:1721:in `<main>'
    #.ok 62 (sample/test.rb:1728:in `<main>')
    # 62
    #sample/test.rb:assignment .ok 1 (sample/test.rb:1732:in `<main>')
    #.ok 2 (sample/test.rb:1733:in `<main>')
    #.ok 3 (sample/test.rb:1737:in `<main>')

    what = nil
    section.scan(%r{^sample/test\.rb:(.*) (?=[.F])|\.ok (\d+) \((.*)\)|not ok (.*) (\d+) -- (.*)\n}) {
      if $1
        what = $1
      elsif $2
        h = {
          "type" => "testrb_result",
          "test_suite" => "testrb",
          "what" => what,
          "testnum" => $2.to_i,
          "location" => $3,
          "result" => "success",
        }
        output_hash h
      else
        h = {
          "type" => "testrb_result",
          "test_suite" => "testrb",
          "what" => $4,
          "testnum" => $5.to_i,
          "location" => $6,
          "result" => "failure",
        }
        output_hash h
      end
    }

    h = nil
    if /^end of test\(test: (\d+)\)/ =~ section
      h = {
        "type" => "testrb_summary",
        "test_suite" => "testrb",
        "tests" => $1.to_i,
        "failures" => 0,
      }
    elsif /^test: (\d+) failed (\d+)/ =~ section || %r{^not ok/test: (\d+) failed (\d+)} =~ section
      h = {
        "type" => "testrb_summary",
        "test_suite" => "testrb",
        "tests" => $1.to_i,
        "failures" => $2.to_i,
      }
    end
    if h
      output_hash h
      h.delete 'test_suite'
      update_last_hash(h, 'testrb')
    end
  end

  TEST_ALL_RESULT_MAP = {
    '.' => 'success',
    'E' => 'error',
    'F' => 'failure',
    'S' => 'skip',
  }
  def scan_test_all(secname, section)
    if /^Finished tests in / =~ section
      list = $`
    else
      # test-all not finished properly?
      list = section
    end
    list.scan(/^(\S+\#.+?) = ([\s\S]*?)(\d+\.\d+) s = ([EFS.])$/) {
      h = {
        "type" => "test_all_result",
        "test_suite" => secname,
        "test_name" => $1,
        "output" => $2,
        "elapsed" => $3.to_f,
        "result" => TEST_ALL_RESULT_MAP.fetch($4, $4),
      }
      output_hash h
    }

    # test/lib/minitest/unit.rb :
    #
    #   e = case e
    #       when MiniTest::Skip then
    #         @skips += 1
    #         return "S" unless @verbose
    #         "Skipped:\n#{klass}##{meth} [#{location e}]:\n#{e.message}\n"
    #       when MiniTest::Assertion then
    #         @failures += 1
    #         "Failure:\n#{klass}##{meth} [#{location e}]:\n#{e.message}\n"
    #       else
    #         @errors += 1
    #         bt = MiniTest::filter_backtrace(e.backtrace).join "\n    "
    #         "Error:\n#{klass}##{meth}:\n#{e.class}: #{e.message}\n    #{bt}\n"
    #       end
    #   @report << e
    #
    # ...
    #
    #   report.each_with_index do |msg, i|
    #     puts "\n%3d) %s" % [i + 1, msg]
    #   end

    section.scan(/^ *\d+\) Failure:\n(\S+) \[(.*)\]:\n((?:.+\n)*)/) {
      h = {
        "type" => "test_all_failure_detail",
        "test_suite" => secname,
        "test_name" => $1,
        "failure_location" => path_after_time($2),
        "detail" => $3
      }
      output_hash h
    }

    section.scan(/^ *\d+\) Error:\n(\S+):\n(\S+): (.*)\n((?:.+\n)*)/) {
      h = {
        "type" => "test_all_error_detail",
        "test_suite" => secname,
        "test_name" => $1,
        "error_class" => $2,
        "error_message" => $3,
        "backtrace" => gsub_path_to_time($4)
      }
      output_hash h
    }

    if /^(\d+) tests, (\d+) assertions, (\d+) failures, (\d+) errors(?:, (\d+) skips)?$/m =~ section
      h = {
        "type" => "test_all_summary",
        "test_suite" => secname,
        "tests" => $1.to_i,
        "assertions" => $2.to_i,
        "failures" => $3.to_i,
        "errors" => $4.to_i,
      }
      h["skips"] = $5.to_i if $5
      output_hash h
      if secname == 'test-all'
        h.delete 'test_suite'
        update_last_hash(h, 'test_all')
      end
    end
  end

  def scan_rubyspec(secname, section)

    # mspec/lib/mspec/runner/formatters/dotted.rb:
    #
    #   outcome = exc.failure? ? "FAILED" : "ERROR"
    #   print "\n#{count += 1})\n#{exc.description} #{outcome}\n"
    #   print exc.message, "\n"
    #   print exc.backtrace, "\n"
    #
    # exc.message may contain newlines.

    section.scan(/^\d+\)\n((?:.+\n)*.*) (FAILED|ERROR)\n((?:.+\n)*)/) {
      h = {
        "type" => "rubyspec_detail",
        "test_suite" => secname,
        "description" => gsub_path_to_time($1),
        "outcome" => $2,
        "detail" => gsub_path_to_time($3)
      }
      output_hash h
    }

    if /^(\d+) files?, (\d+) examples?, (\d+) expectations?, (\d+) failures?, (\d+) errors?$/m =~ section
      h = {
        "type" => "rubyspec_summary",
        "test_suite" => secname,
        "files" => $1.to_i,
        "examples" => $2.to_i,
        "expectations" => $3.to_i,
        "failures" => $4.to_i,
        "errors" => $5.to_i,
      }
      output_hash h
      if secname == 'rubyspec'
        h.delete 'test_suite'
        update_last_hash(h, 'rubyspec')
      end
    end
  end

  def scan_exception(secname, section)
    section.scan(/^(.*)\n(?=(.*:\d+):in `(.*?)'(.*)\((\S+)\)\n\tfrom )/) {
      h = {
        "type" => "exception",
        'secname' => secname,
        "prev_line" => $1,
        "location" => $2,
        "caller_name" => $3,
        "message" => $4.strip,
        "error_class" => $5
      }
      output_hash h
    }
  end

  def scan_bug(secname, section)
    section.scan(/^(.*)\n(?=(.*)\[BUG\](.*))/) {
      prev_line = $1
      line_prefix = $2.strip
      message = $3.strip
      #Expected /#<Bogus:/ to match "-e:3: [BUG] Segmentation fault\nruby ...
      next if /\\n/ =~ line_prefix || /\\n/ =~ message
      h = {
        'type' => 'bug',
        'secname' => secname,
        'prev_line' => prev_line,
        'line_prefix' => line_prefix,
        'message' => message
      }
      output_hash h
    }
  end

  def scan_fatal(secname, section)
    section.scan(/^(.*)\n(?=(.*)\[FATAL\](.*))/) {
      h = {
        'type' => 'fatal',
        'secname' => secname,
        'prev_line' => $1,
        'line_prefix' => $2.strip,
        'message' => $3.strip
      }
      output_hash h
    }
  end

  def scan_make_failure(secname, section)
    section.scan(/^(.*)\n(?=(.*?)g?make: \*\*\* (.*)\n)/) { # GNU make
      h = {
        "type" => "make_failure",
        "secname" => secname,
        "prev_line" => $1,
        "line_prefix" => $2.strip,
        "message" => $3.strip
      }
      output_hash h
    }
  end

  def scan_glibc_failure(secname, section)
    section.scan(/^(.*)\n(?=(.*?)\*\*\* (.*?) \*\*\*(.*)\n)/) {
      h = {
        "type" => "glibc_failure",
        "secname" => secname,
        "prev_line" => $1,
        "line_prefix" => $2.strip,
        "message1" => $3.strip,
        "message2" => $4.strip
      }
      output_hash h
    }
    section.scan(/^(.*)\n(?=(.*): symbol lookup error: (.*): undefined symbol: (\S+)\n)/) {
      h = {
        "type" => "glibc_symbol_lookup_error",
        "secname" => secname,
        "prev_line" => $1,
        "line_prefix" => $2.strip,
        "library" => $3.strip,
        "symbol" => $4.strip
      }
      output_hash h
    }
  end

  def scan_timeout(secname, section)
    section.scan(/^(.*)\n(?=(.*)timeout: ((command execution time exceeds|output interval exceeds|too long line\.) .*)\n)/) {
      h = {
        "type" => "timeout",
        "secname" => secname,
        "prev_line" => $1,
        "line_prefix" => $2.strip,
        "message" => $3.strip
      }
      output_hash h
    }
  end

  def detect_section_failure(secname, section)
    if /^(.*)\nfailed\((.*)\)\n\z/ =~ section
      h = {
        "type" => "section_failure",
        "secname" => secname,
        "prev_line" => $1,
        "message" => $2.strip
      }
      output_hash h
    end
  end

  def extract_info(f)
    first = true
    has_success_section = false
    has_neterror_section = false
    f.each_line("\n== ") {|section|
      section.scrub!
      section.sub!(/\n== \z/, '')
      if first
        if /\A<html>/ =~ section
          $stderr.puts "chkbuild-ruby-info needs text log (not HTML log)."
          exit false
        end
        if /\A== / !~ section
          $stderr.puts "It seems not a chkbuild log."
          exit false
        end
      else
        section = '== ' + section
      end
      if /\n\z/ !~ section
        section << "\n"
      end
      section_line = section.lines.first
      _, secname, rest =  section_line.split(/\s+/, 3)
      scan_section_start(secname, rest)
      scan_first_section(secname, section) if first
      case secname
      when "start"
        scan_start(section)
      when "autoconf-version"
        scan_autoconf_version(section)
      when "bison-version"
        scan_bison_version(section)
      when "svn/ruby", "svn-info/ruby"
        scan_svn(section)
      when "svn"
        scan_svn_old_chkbuild(section)
      when "git/mspec", "git/rubyspec", "git-mspec", "git-rubyspec"
        scan_git(section)
      when "version.h"
        scan_version_h(section)
      when "configure"
        scan_configure(section)
      when "verconf.h"
        scan_verconf_h(section)
      when "config-files"
        scan_config_files(section)
      when "cc-version"
        scan_cc_version(section)
      when "miniruby-libc"
        scan_miniruby_libc(section)
      when "btest"
        scan_btest(secname, section)
      when "test.rb"
        scan_testrb(section)
      when "method-list"
        scan_method_list(section)
      when "showflags"
        scan_showflags(section)
      when "test-knownbug"
        scan_btest(secname, section)
      when "version"
        scan_ruby_v(section)
      when "version-list"
        scan_version_list(section)
      when "abi-check-notitle", "abi-check"
        scan_abi_check(section)
      when "test-all", %r{\Atest/}
        scan_test_all(secname, section)
      when "rubyspec", %r{\Arubyspec/}
        scan_rubyspec(secname, section)
      when "success"
        has_success_section = true
      when "neterror"
        has_neterror_section = true
      end
      if secname != 'title-info'
        scan_exception(secname, section)
        scan_bug(secname, section)
        scan_fatal(secname, section)
      end
      scan_make_failure(secname, section)
      scan_glibc_failure(secname, section)
      scan_timeout(secname, section)
      detect_section_failure(secname, section)
      first = false
    }
    update_last_hash({'status'=> has_success_section ? "success" : has_neterror_section ? "netfail" : "failure" })
    output_hash(@last_hash)
  end

  def extract1(&block)
    with_output_proc(block) {
      extract_info(@f)
    }
  end

  def extract
    extract1 {|hash|
      if @common_hash
        hash = @common_hash.merge(hash) {|k, v1, v2|
          if v1 != v2
            warn "common hash override #{k.inspect}: #{v1.inspect} v.s. #{v2.inspect}"
          end
          v1
        }
      end
      yield hash
    }
  end

  def convert_to_td(out=$stdout)
    extract {|hash|
      tblname = hash["type"]
      tblname.tr!('-','_')
      out.print "@[chkbuild.#{tblname}] "
      out.puts JSON.dump(hash)
    }
  end

  def convert_to_json(out=$stdout)
    @out = out
    output_json_outermost_array {
      extract {|hash|
        output_json_object hash
      }
    }
  end

  def self.optionparser
    o = OptionParser.new
    o.def_option('-h', 'show this message') { puts o; exit }
    o.def_option('--type TYPE,...', 'show only specified types') {|val|
      yield :type, val.split(/,/)
    }
    o.def_option('--disable-sole-record', 'disable sole records') {
      yield :enable_sole_record, false
    }
    o
  end

  def self.open_stdin
    magic = $stdin.read(2).b
    $stdin.ungetc(magic)
    if magic == "\x1f\x8b".b
      Zlib::GzipReader.wrap($stdin) {|f|
        yield f
      }
    else
      yield $stdin
    end
  end

  def self.open_log(filename)
    if /\.gz\z/ =~ filename
      Zlib::GzipReader.open(filename) {|f|
        yield f
      }
    else
      File.open(filename) {|f|
        yield f
      }
    end
  end

  def self.each_argfile(argv)
    if argv.empty?
      open_stdin {|f|
        yield f
      }
    else
      argv.each {|filename|
        open_log(filename) {|f|
          yield f
        }
      }
    end
  end

  def self.main(argv)
    opts = DefaultOption.dup
    optionparser {|k,v| opts[k] = v}.parse!(argv)
    each_argfile(argv) {|f|
      ChkBuildRubyInfo.new(f, opts).convert_to_json
    }
  end

end
