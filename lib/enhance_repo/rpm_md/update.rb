#--
# 
# enhancerepo is a rpm-md repository metadata tool.
# Copyright (C) 2008, 2009 Novell Inc.
# Copyright (C) 2009, Jordi Massager Pla <jordi.massagerpla@opensuse.org>
#
# Author: Duncan Mac-Vicar P. <dmacvicar@suse.de>
#         Jordi Massager Pla <jordi.massagerpla@opensuse.org>
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston,
# MA  02110-1301, USA.  A copy of the GNU General Public License is
# also available at http://www.gnu.org/copyleft/gpl.html.
#
#++
#

require 'rubygems'
require 'builder'
require 'rexml/document'
require 'yaml'
require 'prettyprint'

module EnhanceRepo
  module RpmMd

    #
    # Represents a reference to a external bugreport
    # feature or issue for a software update
    #
    class Reference
      # uri of the reference
      attr_accessor :href
      # its type, for example, bnc (novell's bugzilla)
      attr_accessor :type
      # the id, for example 34561
      # the pair type-id should be globally unique
      attr_accessor :referenceid
      # label to display to the user
      attr_accessor :title

      # initialize a reference, per default a novell
      # bugzilla type
      def initialize
        @href = "http://bugzilla.novell.com"
        @referenceid = "none"
        @title = ""
        @type = "bugzilla"
      end
    end

    # represents one update, which can consist of various packages
    # and references
    class Update
      attr_accessor :updateid
      attr_accessor :status
      attr_accessor :from
      attr_accessor :type
      attr_accessor :version
      attr_accessor :release
      attr_accessor :issued
      attr_accessor :references
      attr_accessor :description
      attr_accessor :title

      attr_accessor :packages
      
      def initialize
        # some default sane values
        @updateid = "unknown"
        @status = "stable"
        @from = "#{ENV['USER']}@#{ENV['HOST']}"
        @type = "optional"
        @version = 1
        @release = "no release"
        @issued = Time.now.to_i
        @references = []
        @description = ""
        @title = "Untitled update"
        @packages = []
      end

      # an update is not empty if it
      # updates something
      def empty?
        @packages.empty?
      end

      def suggested_filename
        "update-#{@updateid}-#{@version}"
      end
      
      # automatically set empty fields
      # needs the description to be set to
      # be somehow smart
      def smart_fill_blank_fields
        # figure out the type (optional is default)
        if description =~ /vulnerability|security|CVE|Secunia/
          @type = 'security'
        else
          @type = 'recommended' if description =~ /fix|bnc#|bug|crash/
        end

        @title << "#{@type} update #{@version} "
        
        # now figure out the title
        # if there is only package
        if @packages.size == 1
          # then name the fix according to the package, and the type
          @title << "for #{@packages.first.name}"
          @updateid = @packages.first.name
        elsif @packages.size < 1
          # do nothing, it is may be just a message
        else
          # figure out what the multiple packages are
          if @packages.grep(/kde/).size > 1
            # assume it is a KDE update
            @title << "for KDE"
            # KDE 3 or KDE4
            @updateid = "KDE3" if @packages.grep(/kde(.+)3$/).size > 1
            @updateid = "KDE4" if @packages.grep(/kde(.+)4$/).size > 1
          elsif @packages.grep(/kernel/).size > 1
            @title << "for the Linux kernel"
            @updateid = 'kernel'
          end
        end
        # now figure out and fill references
        # second format is a weird non correct format some developers use
        # Novell bugzilla
        bugzillas = description.scan(/BNC\:\s?(\d+)|bnc\s?#(\d+)|b\.n\.c (\d+)|n#(\d+)/i)
        bugzillas.each do |bnc|
          ref = Reference.new
          ref.href << "/#{bnc}"
          ref.referenceid = bnc
          ref.title = "bug number #{bnc}"
          @references << ref
        end
        # Redhat bugzilla
        rhbz = description.scan(/rh\s?#(\d+)|rhbz\s?#(\d+)/)
        rhbz.each do |rhbz|
          ref = Reference.new
          ref.href = "http://bugzilla.redhat.com/#{rhbz}"
          ref.referenceid = rhbz
          ref.title = "Redhat's bug number #{rhbz}"
          @references << ref
        end
        # gnome
        bgo = description.scan(/bgo\s?#(\d+)|BGO\s?#(\d+)/)
        bgo.each do |bgo|
          ref = Reference.new
          ref.href << "http://bugzilla.gnome.org/#{bgo}"
          ref.referenceid = bgo
          ref.title = "Gnome bug number #{bgo}"
          @references << ref
        end

        # KDE
        bko = description.scan(/kde\s?#(\d+)|KDE\s?#(\d+)/)
        bko.each do |bko|
          ref = Reference.new
          ref.href << "http://bugs.kde.org/#{bko}"
          ref.referenceid = bko
          ref.title = "KDE bug number #{bko}"
          @references << ref
        end
        # CVE security
        cves = description.scan(/CVE-([\d-]+)/)
        cves.each do |cve|
          ref = Reference.new
          ref.href = "http://cve.mitre.org/cgi-bin/cvename.cgi?name=CVE-#{cve}"
          ref.referenceid = "#{cve}"
          ref.type = 'cve'
          ref.title = "CVE number #{cve}"
          @references << ref
        end

      end
      
      # write a update out
      def write(file)
        builder = Builder::XmlMarkup.new(:target=>file, :indent=>2)
        append_to_builder(builder)
      end
      
      def append_to_builder(builder)  
        builder.update('status' => 'stable', 'from' => @from, 'version' => @version, 'type' => @type) do |b|
          b.title(@title)
          b.id(@updateid)
          b.issued(@issued)
          b.release(@release)
          b.description(@description)
          # serialize attr_reader :eferences
          b.references do |b|
            @references.each do |r|
              b.reference('href' => r.href, 'id' => r.referenceid, 'title' => r.title, 'type' => r.type )   
            end
          end
          # done with references
          b.pkglist do |b|
            b.collection do |b|
              @packages.each do |pkg|
                b.package('name' => pkg.name, 'arch'=> pkg.arch, 'version'=>pkg.version.v, 'release'=>pkg.version.r) do |b|
                  b.filename(File.basename(pkg.path))
                end
              end
            end # </collection>
          end #</pkglist>
          # done with the packagelist
        end
      end
      
    end

  end
end