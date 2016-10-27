require 'aws-sigv4'

module Aws
  module Plugins
    class SignatureV4 < Seahorse::Client::Plugin

      option(:sigv4_signer) do |cfg|
        SignatureV4.build_signer(cfg)
      end

      option(:sigv4_name) do |cfg|
        cfg.api.metadata['signingName'] || cfg.api.metadata['endpointPrefix']
      end

      option(:sigv4_region) do |cfg|
        prefix = cfg.api.metadata['endpointPrefix']
        if cfg.region.nil?
          nil
        elsif prefix && cfg.endpoint.to_s.match(/#{prefix}\.amazonaws\.com/)
          EndpointProvider.signing_region('us-east-1', cfg.sigv4_name)
        else
          EndpointProvider.signing_region(cfg.region, cfg.sigv4_name)
        end
      end

      option(:unsigned_operations) do |cfg|
        cfg.api.operation_names.inject([]) do |unsigned, operation_name|
          if cfg.api.operation(operation_name)['authtype'] != 'none'
            unsigned
          else
            unsigned << operation_name
          end
        end
      end

      def add_handlers(handlers, cfg)
        if cfg.unsigned_operations.empty?
          handlers.add(Handler, step: :sign)
        else
          operations = cfg.api.operation_names - cfg.unsigned_operations
          handlers.add(Handler, step: :sign, operations: operations)
        end
      end

      class Handler < Seahorse::Client::Handler
        def call(context)
          SignatureV4.apply_signature(context.config.sigv4_signer, context)
          @handler.call(context)
        end
      end

      class MissingCredentialsSigner
        def sign_request(*args)
          raise Errors::MissingCredentialsError
        end
      end

      class << self

        # @api private
        def build_signer(cfg)
          if cfg.credentials && cfg.sigv4_region
            Aws::Sigv4::Signer.new(
              service: cfg.sigv4_name,
              region: cfg.sigv4_region,
              credentials_provider: cfg.credentials,
              unsigned_headers: ['content-length', 'user-agent']
            )
          elsif cfg.credentials
            raise Errors::MissingRegionError
          elsif cfg.sigv4_region
            # Instead of raising now, we return a signer that raises only
            # if you attempt to sign a request. Some services have unsigned
            # operations and it okay to initialize clients for these services
            # without credentials. Unsigned operations have an "authtype"
            # trait of "none".
            MissingCredentialsSigner.new
          end
        end

        # @api private
        def apply_signature(signer, context)
          req = context.http_request

          # in case this request is being re-signed
          req.headers.delete('Authorization')
          req.headers.delete('X-Amz-Security-Token')
          req.headers.delete('X-Amz-Date')

          # compute the signature
          begin
            signature = signer.sign_request(
              http_method: req.http_method,
              url: req.endpoint,
              headers: req.headers,
              body: req.body
            )
          rescue Aws::Sigv4::Errors::MissingCredentialsError
            raise Aws::Errors::MissingCredentialsError
          end

          # apply signature headers
          req.headers.update(signature.headers)

          # add request metadata with signature components for debugging
          context[:canonical_request] = signature.canonical_request
          context[:string_to_sign] = signature.string_to_sign
        end

      end
    end
  end
end