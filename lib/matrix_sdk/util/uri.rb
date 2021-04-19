# frozen_string_literal: true

require 'uri'

module URI
  # A mxc:// Matrix content URL
  class MXC < Generic
    def full_path
      select(:host, :port, :path, :query, :fragment)
        .reject(&:nil?)
        .join
    end
  end

  @@schemes['MXC'] = MXC

  if !@@schemes.key? 'MATRIX'
    # A matrix: URI according to MSC2312
    class MATRIX < Generic
      attr_reader :authority, :action, :mxid, :mxid2, :via

      def initialize(*args)
        super(*args)

        @action = nil
        @authority = nil
        @mxid = nil
        @mxid2 = nil
        @via = nil

        if !@opaque && !@path
          raise InvalidComponentError,
            'missing opaque part for matrix URL'
        end
 
        if @path
          @authority = @host
          @authority += ":#{@port}" if @port
        else
          @path, @query = @opaque.split('?')
          @query, @fragment = @query.split('#') if @query&.include? '#'
          @path, @fragment = @path.split('#') if @path&.include? '#'
          @path = "/#{path}"
          @opaque = nil
        end

        components = @path.delete_prefix('/').split('/', -1)
        if components.size != 2 && components.size != 4
          raise InvalidComponentError,
            'component count must be 2 or 4'
        end

        sigil = case components.shift
                when 'u', 'user'
                  '@'
                when 'r', 'room'
                  '#'
                when 'roomid'
                  '!'
                else
                  raise InvalidComponentError,
                    'invalid component in path'
                end

        component = components.shift
        if component.nil? || component.empty?
          raise InvalidComponentError,
            "component can't be empty"
        end

        @mxid = MatrixSdk::MXID.new("#{sigil}#{component}")

        if components.size == 2
          sigil2 = case components.shift
                   when 'e', 'event'
                     '$'
                   else
                     raise InvalidComponentError,
                       'invalid component in path'
                   end
          component = components.shift
          if component.nil? || component.empty?
            raise InvalidComponentError,
              "component can't be empty"
          end

          @mxid2 = MatrixSdk::MXID.new("#{sigil2}#{component}")
        end

        return unless @query

        @action = @query.match(/action=([^&]+)/)&.captures&.first&.to_sym
        @via = @query.scan(/via=([^&]+)/)&.flatten&.compact
      end

      def mxid2?
        !@mxid2.nil?
      end
    end

    @@schemes['MATRIX'] = MATRIX
  end
end

