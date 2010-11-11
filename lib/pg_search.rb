require "active_record"

module PgSearch
  def self.included(base)
    base.send(:extend, ClassMethods)
  end

  module ClassMethods
    def pg_search_scope(name, options)
      options_proc = case options
        when Proc
          options
        when Hash
          lambda { |query|
            options.reverse_merge(
              :query => query
            )
          }
        else
          raise ArgumentError, "#{__method__} expects a Proc or Hash for its options"
      end

      scope_method = if self.respond_to?(:scope) && !protected_methods.include?('scope')
                       :scope
                     else
                       :named_scope
                     end

      send(scope_method, name, lambda { |*args|
        options = options_proc.call(*args).reverse_merge(:using => :tsearch, :normalizing => [])
        query = options[:query]
        normalizing = Array.wrap(options[:normalizing])

        raise ArgumentError, "the search scope #{name} must have :against in its options" unless options[:against]

        columns = Array.wrap(options[:against]).map do |column_name|
          "coalesce(#{quoted_table_name}.#{connection.quote_column_name(column_name)}, '')"
        end

        document = columns.join(" || ' ' || ")

        normalized = lambda do |string|
          string = "unaccent(#{string})" if normalizing.include?(:diacritics)
          string
        end

        tsquery = query.split(" ").compact.map do |term|
          term = "#{term}:*" if normalizing.include?(:prefixes)
          "#{normalized[connection.quote(term)]}::tsquery"
        end.join(" && ")

        tsdocument = columns.map do |column|
          "to_tsvector(#{normalized[column]})"
        end.join(" || ")

        conditions_hash = {
          :tsearch => "(#{tsdocument}) @@ (#{tsquery})",
          :trigram => "(#{normalized[document]}) % #{normalized[":query"]}"
        }

        conditions = Array.wrap(options[:using]).map do |feature|
          "\n\n(#{conditions_hash[feature]})\n\n"
        end.join("OR")

        {:conditions => [conditions, {:query => query}]}
      })
    end
  end
end
