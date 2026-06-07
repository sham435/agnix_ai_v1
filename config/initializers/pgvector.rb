# Register the vector type with the PostgreSQL adapter so ActiveRecord
# can cast Ruby Arrays to/from pgvector text format ("[0.1,0.2]").
# Without this, assigning a Ruby Array to a vector column raises "can't cast Array".

def build_pgvector_type
  ActiveRecord::Type::Value.new.tap do |t|
    def t.type
      :vector
    end

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
  vector_type = build_pgvector_type

  self::NATIVE_DATABASE_TYPES[:vector] = { name: "vector" }

  singleton_class.prepend(Module.new do
    define_method(:initialize_type_map) do |m|
      super(m)
      m.register_type("vector", vector_type)
    end

    define_method(:load_additional_types) do |oids = nil|
      super(oids)
      oid = select_value("SELECT t.oid FROM pg_type t WHERE t.typname = 'vector'").to_i
      if oid > 0
        @type_map.register_type(oid, vector_type)
      end
    rescue => e
      Rails.logger.warn "Could not register vector OID for schema dump: #{e.message}"
    end
  end)

  # Define t.vector "col" method on TableDefinition so schema load works.
  ActiveRecord::ConnectionAdapters::PostgreSQL::TableDefinition.include(
    Module.new do
      def vector(*args, **kwargs)
        column(*args, :vector, **kwargs)
      end
    end
  )
end
