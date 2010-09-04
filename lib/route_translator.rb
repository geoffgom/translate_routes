class RouteTranslator
  attr_writer :default_locale, :dictionary
  attr_accessor :prefix_on_default_locale
  
  
  TRANSLATABLE_SEGMENT = /^(\w+)(\()?/.freeze
  LOCALE_PARAM_KEY = :locale.freeze
  ROUTE_HELPER_CONTAINER = [
    ActionController::Base, 
    ActionView::Base, 
    ActionMailer::Base, 
    ActionDispatch::Routing::UrlFor
  ].freeze
    
    
  class << self
    # Default locale suffix generator
    def locale_suffix locale
      locale.to_s.underscore
    end
    
    def init_with_i18n *wanted_locales
      new.tap do |t|
        t.init_i18n_dictionary *wanted_locales
      end      
    end
    
    def init_with_yield &block
      new.tap do |t|
        t.yield_dictionary &block
      end
    end
    
    def init_from_file file_path, options = {}
      new.tap do |t|
        t.set_options options
        t.load_dictionary_from_file file_path
      end
    end
  end
  
  def initialize
    @prefix_on_default_locale = false
  end
  
  def yield_dictionary
    @dictionary = { default_locale => {}}
    yield @dictionary
    @available_locales = @dictionary.keys.map &:to_s
  end
  
  def load_dictionary_from_file file_path
    @dictionary = { default_locale => {}}
    add_dictionary_from_file file_path
  end
  
  def add_dictionary_from_file file_path    
    yaml = YAML.load_file(file_path)
    yaml.each_pair do |locale, translations|
      merge_translations locale, translations    
    end    
    @available_locales = @dictionary.keys.map &:to_s
  end
  
  def merge_translations locale, translations
    locale = locale.to_s
    if translations.blank?
      @dictionary[locale] ||= {}
      return
    end
    @dictionary[locale] = (@dictionary[locale] || {}).merge(translations)
  end
  
  def set_options options
    @prefix_on_default_locale = options[:prefix_on_default_locale] || false
    @default_locale = options[:default_locale] || I18n.default_locale
  end
  
  def init_i18n_dictionary *wanted_locales
    wanted_locales = available_locales if wanted_locales.blank?
    @dictionary = { default_locale => {}}
    wanted_locales.each do |locale|
      @dictionary[locale] = Hash.new do |hsh, key|
        hsh[key] = I18n.translate key, :locale => locale
      end
    end
    @available_locales = @dictionary.keys.map &:to_s
  end
  
  # Translate a specific RouteSet, usually Rails.application.routes
  def translate route_set    
    Rails.logger.info "Translating routes (default locale: #{default_locale})" if defined?(Rails) && defined?(Rails.logger)
    
    # save original routes and clear route set
    original_routes = route_set.routes.dup                     # Array [routeA, routeB, ...]
    original_named_routes = route_set.named_routes.routes.dup  # Hash {:name => :route}
    
    reset_route_set route_set        
        
    if root_route = original_named_routes[:root]
      add_root_route root_route, route_set
    end    

    original_routes.each do |original_route|
      translations_for(original_route).each do |translated_route_args|
        route_set.add_route *translated_route_args
      end
    end
    
    original_named_routes.each_key do |route_name|
      route_set.named_routes.helpers.concat add_untranslated_helpers_to_controllers_and_views(route_name)
    end
  end
  
  def add_root_route root_route, route_set
    defaults = root_route.defaults.dup
    conditions = root_route.conditions.merge :path_info => "/"
    defaults.merge! LOCALE_PARAM_KEY => default_locale unless prefix_on_default_locale
    
    route_set.add_route root_route.app, conditions, root_route.requirements.dup, defaults, :root    
  end
  
  # Add standard route helpers for default locale e.g.
  #   I18n.locale = :de
  #   people_path -> people_de_path
  #   I18n.locale = :fr
  #   people_path -> people_fr_path
  def add_untranslated_helpers_to_controllers_and_views old_name
    ['path', 'url'].map do |suffix|
      new_helper_name = "#{old_name}_#{suffix}"
      
      ROUTE_HELPER_CONTAINER.each do |helper_container|
        helper_container.send :define_method, new_helper_name do |*args|
          send "#{old_name}_#{locale_suffix(I18n.locale)}_#{suffix}", *args
        end
      end
    
      new_helper_name.to_sym
    end
  end
  
  # Generate translations for route for all available locales
  def translations_for route
    available_locales.map do |locale|
      translate_route route, locale
    end
  end
  
  # Generate translation for a single route for one locale
  def translate_route route, locale
    conditions = { :path_info => translate_path(route.path, locale) }
    conditions[:request_method] = route.conditions[:request_method].source.upcase if route.conditions.has_key? :request_method
    requirements = route.requirements.merge LOCALE_PARAM_KEY => locale
    defaults = route.defaults.merge LOCALE_PARAM_KEY => locale
    new_name = "#{route.name}_#{locale_suffix(locale)}" if route.name
    
    [route.app, conditions, requirements, defaults, new_name]
  end
  
  def add_prefix? locale
    @prefix_on_default_locale || !default_locale?(locale)
  end
  
  def root_route? route
    route.name == :root
  end
  
  def translate_path path, locale
    new_path = if path == "/(.:format)"
      ""
    else      
      segments = path.split("/").map do |path_segment|
        translate_path_segment(path_segment, locale)
      end
    
      segments.join "/"
    end
    
    if add_prefix? locale
      new_path = "/:#{LOCALE_PARAM_KEY}" + new_path
    end
    return "/" if new_path.blank?
    
    new_path
  end
  
  def translate_path_segment segment, locale
    return segment if segment.blank? or segment.starts_with?(":")
    
    match = TRANSLATABLE_SEGMENT.match(segment)[1] rescue nil

    translate_string(match, locale) || segment
  end
  
  def available_locales
    @available_locales ||= I18n.available_locales.map(&:to_s)
  end
  
  def available_locales= locales
    @available_locales = locales.map(&:to_s)
  end
  
  def default_locale
    @default_locale ||= I18n.default_locale.to_s
  end
  
  def default_locale? locale
    default_locale == locale.to_s
  end
  
  def dictionary
    @dictionary || init_dictionary
  end
  
  def translate_string str, locale
    dictionary[locale.to_s][str.to_s]
  end
  
  def locale_suffix locale
    self.class.locale_suffix locale
  end
  
  private
  
  def init_dictionary
    @dictionary = {}
    available_locales.each do |locale|
      @dictionary[locale] = {}
    end
    
    @dictionary
  end  
  
  def reset_route_set route_set
    route_set.clear!
    remove_all_methods_in route_set.named_routes.module
  end
  
  def remove_all_methods_in mod
    mod.instance_methods.each do |method|
      mod.send :remove_method, method
    end
  end
end

module ActionDispatch
  module Routing
    module Translator
      class << self
        def translate &block  
          RouteTranslator.init_with_yield(&block).translate Rails.application.routes
        end
        
        def translate_from_file *file_path
          RouteTranslator.init_from_file(File.join(file_path)).translate Rails.application.routes
        end
        
        def i18n *locales
          RouteTranslator.init_with_i18n(*locales).translate Rails.application.routes
        end
      end
    end
  end
end   

# Add set_locale_from_url to controllers
# also works in Rails 3
ActionController::Base.class_eval do 
  private
  # called by before_filter
  def set_locale_from_url            
    # use ActionDispatch in Rails 3
    I18n.locale = params[RouteTranslator::LOCALE_PARAM_KEY]
    default_url_options({RouteTranslator::LOCALE_PARAM_KEY => I18n.locale })
  end
end

# Add locale_suffix to controllers, views and mailers   
# also works in Rails 3
RouteTranslator::ROUTE_HELPER_CONTAINER.each do |klass|
  klass.class_eval do
    private
    def locale_suffix locale
      # use ActionDispatch in Rails 3
      RouteTranslator.locale_suffix locale
    end
  end
end