require 'rubygems'
require 'builder'
require 'rexml/document'
require 'digest/sha1'
require 'enhancerepo/constants'
require 'zlib'
require 'yaml'

include REXML

# represents a resource in repomd.xml
class RepoMdResource
  attr_accessor :type
  attr_accessor :location, :checksum, :timestamp, :openchecksum

  # define equality based on the location
  # as it has no sense to have two resources for the
  #same location
  def ==(other)
    return (location == other.location) if other.is_a?(RepoMdResource)
    false
  end
  
end

# represents the repomd index
class RepoMdIndex
  attr_accessor :products, :keywords

  # constructor
  # repomd - repository
  def initialize
    @resources = []
  end

  # add a file resource. Takes care of setting
  # all the metadata.
  
  def add_file_resource(abspath, path, type=nil)
    r = RepoMdResource.new
    r.type = type
    # figure out the type of resource
    # the extname to remove is different if it is gzipped
    ext = File.extname(path)
    base = File.basename(path, ext)

    # if it was gzipped, repeat the operation
    # to get the real basename
    if ext == '.gz'
      ext = File.extname(base)
      base = File.basename(base, ext)
    end
      
    r.type = base if r.type.nil?
    r.location = abspath
    r.timestamp = File.mtime(path).to_i.to_s
    r.checksum = Digest::SHA1.hexdigest(File.new(path).read)
    r.openchecksum = r.checksum
    if File.extname(path) == '.gz'
      # we have a different openchecksum
      r.openchecksum = Digest::SHA1.hexdigest(Zlib::GzipReader.new(File.new(path)).read)
    end
    add_resource(r)
    
  end

  # add resource
  # any resource of the same location
  # is overwritten
  def add_resource(r)
    # first check if this resource is already in
    # if yes then override it
    if (index = @resources.index(r)).nil?
      # add it
      @resources << r
    else
      # replace it
      STDERR.puts("#{r.location} already exists. Replacing.")
      @resources[index] = r
    end
  end
  
  # read data from a file
  def read_file(file)
    doc = Document.new(file)
    doc.elements.each('repomd/data') do |datael|
      resource = RepoMdResource.new
      resource.type = datael.attributes['type']
      datael.elements.each do |attrel|
        case attrel.name
          when 'location'
            resource.location = attrel.attributes['href']
          when 'checksum'
            resource.checksum = attrel.text
          when 'timestamp'
            resource.timestamp = attrel.text
          when 'open-checksum'
            resource.openchecksum = attrel.text
          else
            raise "unknown tag #{attrel.name}"
        end # case
      end # iterate over data subelements
      add_resource(resource)
    end # iterate over data elements
  end
  
  # write the index to xml file
  def write(file)
    builder = Builder::XmlMarkup.new(:target=>file, :indent=>2)
    builder.instruct!
    xml = builder.repomd('xmlns' => "http://linux.duke.edu/metadata/repo") do |b|
      @resources.each do |resource|
        b.data('type' => resource.type) do |b|
          b.location('href' => resource.location)
          b.checksum(resource.checksum, 'type' => 'sha')
          b.timestamp(resource.timestamp)
          b.tag!('open-checksum', resource.openchecksum, 'type' => 'sha')
        end
      end
      
    end #builder
    
  end
    
end

class PackageId
  attr_accessor :name, :version, :release, :arch, :epoch
  attr_accessor :checksum

  def initialize(rpmfile)
    STDERR.puts "Reading #{rpmfile} information..."
    @name, @arch, @version, @epoch, @release, @checksum = `rpm -qp --queryformat "%{NAME} %{ARCH} %{VERSION} %{EPOCH} %{RELEASE}" #{rpmfile}`.split(' ')
    @checksum = Digest::SHA1.hexdigest(File.new(rpmfile).read)
  end
  
  def eql(other)
      return checksum.eql?(other.checksum)
  end

  def hash
    checksum
  end

  def to_s
    "#{name}-#{version}-#{release}-#{arch}(#{checksum})"
  end
end

# represents a set non standard data tags
# but it is not part of the standard, yet still associated
# with a particular package (so with primary.xml semantics
class ExtraPrimaryData
  # initialize the extra data with a name
  def initialize(name)
    @name = name
    # the following hash automatically creates a sub
    # hash for non found values
    @properties = Hash.new { |h,v| h[v]= Hash.new }

  end

  # add an attribute named name for a
  # package identified with pkgid
  def add_attribute(pkgid, name, value)
    @properties[pkgid][name] = value
  end

  def empty?
    @properties.empty?
  end

  # write an extension file like other.xml
  def write(file)
    builder = Builder::XmlMarkup.new(:target=>file, :indent=>2)
    builder.instruct!
    xml = builder.tag!(@name) do |b|
      @properties.each do |pkgid, props|
        b.package('pkgid' => pkgid.checksum, 'name' => pkgid.name) do |b|
          b.version('ver' => pkgid.version, 'rel' => pkgid.release, 'arch' => pkgid.arch, 'epoch' => 0.to_s )
          props.each do |propname, propvalue|
            b.tag!(propname, propvalue)
          end
        end # end package tag
      end # iterate over properties
    end #done builder
  end
  
end

# represents SUSE extensions to repository
# metadata (not associated with packages)
class SuseInfo

  # expiration time
  # the generated value is
  # still calculated from repomd.xml
  # resources
  attr_accessor :expire
  attr_accessor :products
  attr_accessor :keywords
  
  def initialize(dir)
    @dir = dir
    @keywords = Set.new
    @products = Set.new
  end

  def empty?
    @expire.nil? and @products.empty? and @keywords.empty?
  end
  
  def write(file)
    builder = Builder::XmlMarkup.new(:target=>file, :indent=>2)
    builder.instruct!
    xml = builder.suseinfo do |b|

      # add expire tag
      b.expire(@expire.to_i.to_s)

      if not @keywords.empty?
        b.keywords do |b|
          @keywords.each do |k|
            b.k(k)
          end
        end
      end

      if not @products.empty?
        b.products do |b|
          @products.each do |p|
            b.id(p)
          end
        end
      end

    end
  end
end

# represents SUSE extensions to
# primary data
class SuseData < ExtraPrimaryData

  def initialize(dir)
    super('susedata')
    @dir = dir
  end

  def add_eulas
    # add eulas
    Dir["#{@dir}/**/*.eula"].each do |eulafile|
      base = File.basename(eulafile, '.eula')
      # =>  look for all rpms with that name in that dir
      Dir["#{File.dirname(eulafile)}/#{base}*.rpm"].each do | rpmfile |
        pkgid = PackageId.new(rpmfile)
        if base == pkgid.name
          eulacontent = File.new(eulafile).read
          add_attribute(pkgid, 'eula', eulacontent)
          STDERR.puts "Adding eula: #{eulafile.to_s}"
        end
      end
    end
    # end of directory iteration
  end
  
end

class UpdateInfo

  def initialize(dir)
    @dir = dir
    @nodes = []
  end

  def empty?
    return @nodes.empty?
  end
  
  def add_updates
    Dir["#{@dir}/**/*.update"].each do |updatefile|
      node = YAML.load(File.new(updatefile).read)
      STDERR.puts("Adding update #{updatefile}")
      @nodes << node
    end
    # end of directory iteration
  end

  # write a update out
  def write(file)
    builder = Builder::XmlMarkup.new(:target=>file, :indent=>2)
    builder.instruct!
    xml = builder.updates do |b|
      @nodes.each do |updates|
        updates.each do |k, v|
          # k is update here
          # v are the attributes
          # default patch issuer
          puts v.inspect
          from = "#{ENV['USER']}@#{ENV['HOST']}"
          type = "optional"
          version = "1"
          from = v['from'] ? v['from'] : from
          type = v['type'] if not v['type'].nil?
          version = v['version'] if not v['version'].nil?
          
          b.update('status' => 'stable', 'from' => from, 'version' => version, 'type' => type) do |b|
            b.title(v['summary'])
            b.id(v['id'] ? v['id'] : "no-id")
            b.issued(v['issued'] ? v['issued'] : Time.now.to_i.to_s )
            b.release(v['release'])
            b.description(v['description'])
            b.references do |b|
              v['references'].each do |k,v|
                b.reference(v)
              end   
            end
          end
        end
      end
    end #done builder

  end
end


class RepoMd

  attr_accessor :index

  # extensions
  attr_reader :susedata, :suseinfo
  
  def initialize(dir)
    @index = RepoMdIndex.new
    # populate the index
    @index.read_file(File.new(File.join(dir, REPOMD_FILE)))    
    @dir = dir
    @susedata = SuseData.new(dir)
    @updateinfo = UpdateInfo.new(dir)
    @suseinfo = SuseInfo.new(dir)
  end

  def sign(keyid)
    # check if the index is written to disk
    repomdfile = File.join(@dir, REPOMD_FILE)
    if not File.exists?(repomdfile)
      raise "#{repomdfile} does not exist."
    end
    # call gpg to sign the repository
    `gpg -sab -u #{keyid} -o #{repomdfile}.asc #{repomdfile}`
    if not File.exists?("#{repomdfile}.asc")
      STDERR.puts "Could't not generate signature #{repomdfile}.asc"
      exit(1)
    else
      STDERR.puts "#{repomdfile}.asc signature generated"
    end

    # now export the public key
    `gpg --export -a -o #{repomdfile}.key #{keyid}`

    if not File.exists?("#{repomdfile}.key")
      STDERR.puts "Could't not generate public key #{repomdfile}.key"
      exit(1)
    else
      STDERR.puts "#{repomdfile}.key public key generated"
    end
  end

  # write back the metadata
  def write
    repomdfile = File.join(@dir, REPOMD_FILE)
    susedfile = "#{File.join(@dir, SUSEDATA_FILE)}.gz"
    updateinfofile = "#{File.join(@dir, UPDATEINFO_FILE)}.gz"
    suseinfofile = "#{File.join(@dir, SUSEINFO_FILE)}.gz"
   
    write_gz_extension_file(@updateinfo, updateinfofile, UPDATEINFO_FILE)
    write_gz_extension_file(@susedata, susedfile, SUSEDATA_FILE)
    write_gz_extension_file(@suseinfo, suseinfofile, SUSEINFO_FILE)
    
    # now write the index
    f = File.open(File.join(@dir, REPOMD_FILE), 'w')
    STDERR.puts "Saving #{repomdfile} .."
    @index.write(f)
    
  end

  # writes an extension to an xml filename if
  # the extension is not empty
  def write_gz_extension_file(extension, filename, relfilename)
    if not extension.empty?
      repomdfile = File.join(@dir, REPOMD_FILE)
      STDERR.puts "Saving #{filename} .."
      f = File.open(filename, 'w')
      # compress the output
      gz = Zlib::GzipWriter.new(f)
      extension.write(gz)
      gz.close
      # add it to the index
      STDERR.puts "Adding #{filename} to #{repomdfile} index"
      @index.add_file_resource("#{relfilename}.gz", filename)
    end
  end
  
end
