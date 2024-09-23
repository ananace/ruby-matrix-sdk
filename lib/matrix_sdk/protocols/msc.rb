# frozen_string_literal: true

# Preliminary support for unmerged MSCs (Matrix Spec Changes)
module MatrixSdk::Protocols::MSC
  def self.add_impl(mod, num, feature: nil, &test)
    raise 'Must provide either unstable feature or test block' unless feature || block_given?

    (@available_mscs ||= []) << { num:, mod:, feature:, block: test }
  end

  def self.available_mscs
    @available_mscs
  end

  def self.extended(api)
    Dir[File.join(__dir__, 'msc', '*.rb')].each { |file| require file }

    (@available_mscs ||= [])
      .each { |v| api.extend v[:mod] if api.has_msc? v[:num] }
  end

  # Check if there's support for MSC2108 - Sync over Server Sent Events
  def has_msc?(num)
    @mscs ||= {}
    return @mscs[num] if @mscs.key? num
    return false unless num

    msc = MatrixSdk::Protocols::MSC.available_mscs.find { |m| m[:num] == num }
    return unless msc

    @mscs[msc[:num]] = begin
      if msc[:feature]
        client_api_unstable_features.has? msc[:feature]
      else
        msc[:block].call
      end
    end
  end
end
