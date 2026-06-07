# Register the vector type with the PostgreSQL adapter so ActiveRecord
# can cast Ruby Arrays to/from pgvector text format ("[0.1,0.2]").
# Without this, assigning a Ruby Array to a vector column raises "can't cast Array".

def build_pgvector_type
  ActiveRecord::Type::Value.new.tap do |t|
    def t.cast(v)
      case v
      when Array then v
      when String then v[1..-2].to_s.split(",").map(&:to_f)
      else v
      end
    end

    def t.serialize(v)
      case v
      when Array then "[#{v.join(',')}]"
      else v
      end
    end

    def t.deserialize(v)
      case v
      when String then v[1..-2].to_s.split(",").map(&:to_f)
      else v
      end
    end
  end
end

ActiveSupport.on_load(:active_record_postgresqladapter) do
  self::NATIVE_DATABASE_TYPES[:vector] = { name: "vector" }

  vector_type = build_pgvector_type

  singleton_class.prepend(Module.new do
    define_method(:initialize_type_map) do |m|
      super(m)
      m.register_type("vector", vector_type)
    end
  end)
end
