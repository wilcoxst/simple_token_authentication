module SimpleTokenAuthentication
  module ActsAsTokenAuthenticationHandlerMethods
    extend ActiveSupport::Concern

    # Please see https://gist.github.com/josevalim/fb706b1e933ef01e4fb6
    # before editing this file, the discussion is very interesting.

    included do
      private :authenticate_entity_from_token!
      private :header_token_name
      private :header_id_name

      # This is necessary to test which arguments were passed to sign_in
      # from authenticate_entity_from_token!
      # See https://github.com/gonzalo-bulnes/simple_token_authentication/pull/32
      ActionController::Base.send :include, Devise::Controllers::SignInOut if Rails.env.test?
    end

    def authenticate_entity!(entity_class)
      # Caution: entity should be a singular camel-cased name but could be pluralized or underscored.
      self.method("authenticate_#{entity_class.name.singularize.underscore}!".to_sym).call
    end


    # The ID and token can be passed in the header or as parameters.
    # The header is given precendence.
    def authenticate_entity_from_token!(entity_class)
      # Set the authentication token params if not already present,
      # see http://stackoverflow.com/questions/11017348/rails-api-authentication-by-headers-token
      params_token_name = "#{entity_class.name.singularize.underscore}_token".to_sym
      params_id_name = "#{entity_class.name.singularize.underscore}_id".to_sym

      if request.headers[header_id_name(entity_class)].blank?
        puts 'User ID header not found, using param'
        id = params[params_id_name]
      else
        puts 'User ID header found'
        id = request.headers[header_id_name(entity_class)]
      end

      if request.headers[header_token_name(entity_class)].blank?
        puts 'Token header not found, using param'
        token = params[params_token_name]
      else
        puts 'Token header found'
        token = request.headers[header_token_name(entity_class)]
      end

      # See https://github.com/ryanb/cancan/blob/1.6.10/lib/cancan/controller_resource.rb#L108-L111
      entity = nil
      if entity_class.respond_to? "find_by"
        entity = id && entity_class.find_by(id: id)
      elsif entity_class.respond_to? "find_by_id"
        entity = id && entity_class.find_by_id(id)
      end

      puts 'Hello from simple_token_authentication'

      # Notice how we use Devise.secure_compare to compare the token
      # in the database with the token given in the params, mitigating
      # timing attacks.
      if entity && Devise.secure_compare(entity.authentication_token, token)

        puts 'Token matches, signing in'

        # Sign in using token should not be tracked by Devise trackable
        # See https://github.com/plataformatec/devise/issues/953
        env["devise.skip_trackable"] = true

        # Notice the store option defaults to false, so the entity
        # is not actually stored in the session and a token is needed
        # for every request. That behaviour can be configured through
        # the sign_in_token option.
        sign_in entity, store: SimpleTokenAuthentication.sign_in_token
      end
    end

    # Private: Return the name of the header to watch for the token authentication param
    def header_token_name(entity_class)
      if SimpleTokenAuthentication.header_names["#{entity_class.name.singularize.underscore}".to_sym].presence
        SimpleTokenAuthentication.header_names["#{entity_class.name.singularize.underscore}".to_sym][:authentication_token]
      else
        "X-#{entity_class.name.singularize.camelize}-Token"
      end
    end

    # Private: Return the name of the header to watch for the user_id param
    def header_id_name(entity_class)
      if SimpleTokenAuthentication.header_names["#{entity_class.name.singularize.underscore}".to_sym].presence
        SimpleTokenAuthentication.header_names["#{entity_class.name.singularize.underscore}".to_sym][:id]
      else
        "X-#{entity_class.name.singularize.camelize}-ID"
      end
    end
  end

  module ActsAsTokenAuthenticationHandler
    extend ActiveSupport::Concern

    # I have insulated the methods into an additional module to avoid before_filters
    # to be applied by the `included` block before acts_as_token_authentication_handler_for was called.
    # See https://github.com/gonzalo-bulnes/simple_token_authentication/issues/8#issuecomment-31707201

    included do
      # nop
    end

    module ClassMethods
      def acts_as_token_authentication_handler_for(entity, options = {})
        options = { fallback_to_devise: true }.merge(options)

        include SimpleTokenAuthentication::ActsAsTokenAuthenticationHandlerMethods

        define_acts_as_token_authentication_helpers_for(entity)

        authenticate_method = if options[:fallback_to_devise]
          :"authenticate_#{entity.name.singularize.underscore}_from_token!"
        else
          :"authenticate_#{entity.name.singularize.underscore}_from_token"
        end
        before_filter authenticate_method, options.slice(:only, :except)
      end

      def acts_as_token_authentication_handler
        ActiveSupport::Deprecation.warn "`acts_as_token_authentication_handler()` is deprecated and may be removed from future releases, use `acts_as_token_authentication_handler_for(User)` instead.", caller
        acts_as_token_authentication_handler_for User
      end

      def define_acts_as_token_authentication_helpers_for(entity_class)
        entity_underscored = entity_class.name.singularize.underscore

        class_eval <<-METHODS, __FILE__, __LINE__ + 1
          def authenticate_#{entity_underscored}_from_token
            authenticate_entity_from_token!(#{entity_class.name})
          end

          def authenticate_#{entity_underscored}_from_token!
            authenticate_entity_from_token!(#{entity_class.name})
            authenticate_entity!(#{entity_class.name})
          end
        METHODS
      end
    end
  end
end
ActionController::Base.send :include, SimpleTokenAuthentication::ActsAsTokenAuthenticationHandler
