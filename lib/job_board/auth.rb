# frozen_string_literal: true

require 'base64'

require 'job_board'

require 'jwt'
require 'rack/auth/abstract/handler'
require 'rack/auth/abstract/request'

module JobBoard
  class Auth < Rack::Auth::AbstractHandler
    module GuestDetect
      def guest?
        (env['REMOTE_USER'] || 'notset') == 'guest'
      end
    end

    def initialize(app, secret: nil, alg: 'RS512', site_paths: /.*/)
      @app = app
      @alg = alg
      @secret = secret || JobBoard.config.jwt_public_key
      @site_paths = site_paths
      @verify = true
    end

    attr_reader :alg, :secret, :verify, :site_paths

    def call(env)
      auth = Request.new(env)

      if site_paths =~ auth.request.path_info &&
         !env.key?('HTTP_TRAVIS_SITE')
        return [
          412,
          { 'Content-Type' => 'application/json' },
          [JSON.dump('@type' => 'error', error: 'missing Travis-Site header')]
        ]
      end

      return unauthorized unless auth.provided?
      return bad_request unless auth.basic? || auth.bearer?

      env['travis.site'] = env.fetch('HTTP_TRAVIS_SITE', '?')
      env['travis.infra'] = env.fetch('HTTP_TRAVIS_INFRASTRUCTURE', '')

      if basic_valid?(auth)
        env['REMOTE_USER'] = auth.basic_username
        return @app.call(env)
      end

      begin
        decode_jwt!(auth)
      rescue JWT::DecodeError => e
        JobBoard.logger.warn('failed to decode jwt', error: e.to_s)
        return unauthorized
      end

      if bearer_valid?(auth)
        env['jwt.header'] = auth.jwt_header
        env['jwt.payload'] = auth.jwt_payload
        return @app.call(env)
      end

      unauthorized
    end

    private def challenge
      'Basic realm="job-board"'
    end

    private def basic_valid?(auth)
      return true if auth.basic_credentials == %w[guest guest]

      auth_tokens.include?(auth.basic_credentials.last) ||
      auth_tokens.include?(auth.basic_credentials)
    end

    private def bearer_valid?(auth)
      return false if auth.job_id.nil?
      return false if auth.params.empty?
      return false if auth.jwt_header.nil? || auth.jwt_payload.nil?

      true
    end

    private def decode_jwt!(auth)
      auth.jwt_payload, auth.jwt_header = JWT.decode(
        auth.params, secret, verify,
        algorithm: alg, verify_sub: true, 'sub' => auth.job_id
      )
    end

    private def auth_tokens
      @auth_tokens ||= build_auth_tokens
    end

    private def build_auth_tokens
      return raw_auth_tokens.split(':').map(&:strip) unless raw_auth_tokens.include?(',')

      raw_auth_tokens.split(',').map do |pair|
        pair.split(':').map(&:strip)
      end
    end

    private def raw_auth_tokens
      @raw_auth_tokens ||= JobBoard.config.auth.tokens
    end

    class Request < Rack::Auth::AbstractRequest
      def job_id
        (%r{jobs/(\d+)}.match(request.path_info) || [])[1]
      end

      def basic?
        scheme == 'basic'
      end

      def bearer?
        scheme == 'bearer'
      end

      def basic_credentials
        @basic_credentials ||= Base64.decode64(params).split(/:/, 2)
      end

      def basic_username
        basic_credentials.first
      end

      attr_accessor :jwt_payload, :jwt_header
    end
  end
end
