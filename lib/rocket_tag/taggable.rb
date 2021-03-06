require 'squeel'
module Squeel
  module Adapters
    module ActiveRecord
      module RelationExtensions

        # The purpose of this call is to close a query and make
        # it behave as a simple table or view. If a query has
        # aggregate functions applied then downstream active
        # relation chaining causes unpredictable behaviour.
        #
        # This call isolates the group by behaviours.
        def isolate_group_by_as(type)
          type.from(self.arel.as(type.table_name))
        end

        # We really only want to group on id for practical
        # purposes but POSTGRES requires that a group by outputs
        # all the column names not under an aggregate function.
        #
        # This little helper generates such a group by
        def group_by_all_columns
          cn = self.column_names
          group { cn.map { |col| __send__(col) } }
        end

        def exists
        end
 
      end
    end
  end
end

module RocketTag
  module Taggable
    def self.included(base)
      base.extend ClassMethods
      #base.send :include, InstanceMethods
    end

    class Manager

      attr_reader :contexts
      attr_writer :contexts
      attr_reader :klass

      def self.parse_tags list
        require 'csv'
        if list.kind_of? String
          # for some reason CSV parser cannot handle
          #     
          #     hello, "foo"
          #
          # but must be
          #
          #     hello,"foo"
          return [] if list.empty?
          list = list.gsub /,\s+"/, ',"'
          list = list.parse_csv.map &:strip
        else
          list
        end
      end

      def initialize klass
        @klass = klass
        @contexts = Set.new
        setup_relations
      end

      def setup_relations
        klass.has_many :taggings , :dependent => :destroy , :as => :taggable, :class_name => "RocketTag::Tagging"
        klass.has_many :tags     , :source => :tag, :through => :taggings, :class_name => "RocketTag::Tag"
      end
    end

    def taggings_for_context context
      taggings.where{taggings.context==context.to_s}
    end

    def destroy_tags_for_context context
      taggings_for_context(context).delete_all
    end

    module InstanceMethods
      def reload_with_tags(options = nil)
        self.class.rocket_tag.contexts.each do |context|
          write_context context, []
        end
        @tags_cached = false
        cache_tags
        reload_without_tags(options)
      end

      def cache_tags
        unless @tags_cached
          tags_by_context ||= send("taggings").group_by{|f| f.context }
          tags_by_context.each do |context,v|
            write_context context, v.map{|t| t.tag.name}
          end
          @tags_cached = true
        end
      end

      def write_context context, list
        @contexts ||= {}
        @contexts[context.to_sym] = list
      end

      def read_context context
        @contexts ||= {}
        @contexts[context.to_sym] || []
      end


      def tagged_similar options = {}
        context = options.delete :on
        if context
          raise Exception.new("#{context} is not a valid tag context for #{self.class}") unless self.class.rocket_tag.contexts.include? context
        end
        if context
          contexts = [context]
        else
          contexts = self.class.rocket_tag.contexts
        end

        if contexts.size > 1
          contexts = contexts.delete :tag
        end

        contexts = contexts.reject do |c|
          send(c.to_sym).size == 0
        end

        conditions = contexts.map do |context|
          _tags = send context.to_sym
          self.class.squeel do
            (tags.name.in(_tags) & (taggings.context == context.to_s))
          end
        end

        condition = conditions.inject do |s, t|
          s | t
        end

        r = self.class.
          joins{tags}.
          where{condition}.
          where{~id != my{id}}

        self.class.count_tags(r)

      end
    end

    module ClassMethods

      def rocket_tag
        @rocket_tag ||= RocketTag::Taggable::Manager.new(self)
      end

      # Provides the tag counting functionality by adding an
      # aggregate count on id. Assumes valid a join has been
      # made.
      #
      # Note that I should be able to chain count tags to 
      # the relation instead of passing the rel parameter in
      # however my tests fails with wrong counts. This is
      # not so elegant
      def count_tags(rel)
        rel.select('*').
        select{count(~id).as(tags_count)}.
        group_by_all_columns.
        order("tags_count DESC").
        isolate_group_by_as(self)
      end

      # Filters tags according to
      # context. context param can
      # be either a single context
      # id or an array of context ids
      def with_tag_context context
        if context
          if context
            if context.class == Array
              contexts = context
            else
              contexts = [context]
            end
          else
            contexts = []
          end

          conditions = contexts.map do |context|
            squeel do
              (taggings.context == context.to_s)
            end
          end

          condition = conditions.inject do |s, t|
            s | t
          end

          where{condition}
        else
          where{ }
        end
      end


      # Generates a sifter or a where clause depending on options.
      # The sifter generates a subselect with the body of the
      # clause wrapped up so that it can be used as a condition
      # within another squeel statement. 
      #
      # Query optimization is left up to the SQL engine.
      def tagged_with_sifter tags_list, options = {}
        options[:sifter] = true
        tagged_with tags_list, options
      end

      # Generates a query that provides the matches
      # along with an extra column :tags_count.
      def tagged_with tags_list, options = {}

        r = joins{tags}.
            where{tags.name.in(tags_list)}.
            with_tag_context(options.delete :on)


        r = count_tags(r)

        if options.delete :all
          r = r.where{tags_count==tags_list.length}
        elsif min = options.delete(:min)
          r = r.where{tags_count>=min}
        end

        if options.delete :sifter
          squeel do
            id.in(r.select{"id"})
          end
        else
          r
        end

      end

      # Generates a query that returns list of popular tags
      # for given model with an extra column :tags_count.
      def popular_tags options={}

        r = 
            RocketTag::Tag.
            joins{taggings}.
            with_tag_context(options.delete :on).
            by_taggable_type(self)

        r = count_tags(r)

        if min = options.delete(:min)
          r = r.where{tags_count>=min}
        end

        r
      end

      def setup_for_rocket_tag
        unless @setup_for_rocket_tag
          @setup_for_rocket_tag = true
          class_eval do
            default_scope do
              preload{taggings}.preload{tags}
            end

            before_save do
              @tag_dirty ||= Set.new

              @tag_dirty.each do |context|
                # Get the current tags for this context
                list = send(context)

                # Destroy all taggings
                destroy_tags_for_context context

                # Find existing tags
                exisiting_tags = Tag.where{name.in(list)}
                exisiting_tag_names = exisiting_tags.map &:name

                # Find missing tags
                tags_names_to_create = list - exisiting_tag_names 

                # Create missing tags
                created_tags = tags_names_to_create.map do |tag_name|
                  Tag.create :name => tag_name
                end

                # Recreate taggings
                tags_to_assign = exisiting_tags + created_tags

                tags_to_assign.each do |tag|
                  tagging = Tagging.new :tag => tag, 
                    :taggable => self, 
                    :context => context, 
                    :tagger => nil
                  self.taggings << tagging
                end
              end
              @tag_dirty = Set.new
            end
          end
        end
      end

      def attr_taggable *contexts
        unless class_variable_defined?(:@@acts_as_rocket_tag)
          include RocketTag::Taggable::InstanceMethods
          class_variable_set(:@@acts_as_rocket_tag, true)
          alias_method_chain :reload, :tags
        end

        if contexts.blank?
          contexts = [:tag]
        end

        rocket_tag.contexts += contexts

        setup_for_rocket_tag

        contexts.each do |context|
          class_eval do

            has_many "#{context}_taggings".to_sym, 
              :source => :taggable,  
              :as => :taggable,
              :conditions => { :context => context }

            has_many "#{context}_tags".to_sym,
              :source => :tag,
              :through => :taggings,
              :conditions => [ "taggings.context = ?", context ]


            validate context do
              if not send(context).kind_of? Enumerable
                errors.add context, :invalid
              end
            end


            # Return an array of RocketTag::Tags for the context
            define_method "#{context}" do
              cache_tags
              read_context(context)
            end


            define_method "#{context}=" do |list|
              list = Manager.parse_tags list

              # Ensure the tags are loaded
              cache_tags
              write_context(context, list)

              (@tag_dirty ||= Set.new) << context


            end
          end
        end
      end
    end
  end
end
