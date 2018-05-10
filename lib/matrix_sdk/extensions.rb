module URI
  class MATRIX < Generic
    def full_path
      select(:host, :port, :path, :query, :fragment)
        .reject(&:nil?)
        .join
    end
  end

  @@schemes['MXC'] = MATRIX
end
