# frozen_string_literal: true

=begin
This class is responsible for managing any actions that require second factor
authentication before a user is allowed to perform them. Such actions include
granting another user admin access, changing password and signing in. In a more
technical sense, an action is the logic encapsulated in a Rails controller
action without the logic related to 2fa enforcement/handling.

When a user attempts to perform a 2fa-protected action, there are 3 possible
outcomes:

1. the user doesn't have any suitable 2fa methods enabled, so they should be
allowed to perform the action right away.

2. the user has a suitable 2fa method enabled, in which case there are 2
possibilities:
  a. the user hasn't done 2fa for the action so they should be redirected to
  the 2fa page and complete the 2fa before they are allowed to proceed.
  b. the user has done 2fa for the action so they should be allowed to perform
  the action.

This class, the auth manager, contains the logic for deciding which outcome
should happen and performing it.

To use the auth manager for requiring 2fa for an action, it needs to be invoked
from the controller action using the `run_second_factor!` method which is
available in all controllers. This method takes a single argument which is a
class that inherits from the `SecondFactor::Actions::Base` class and implements
the following methods:

1. no_second_factors_enabled!(params):
  This method corresponds to outcome (1) above, i.e. it's called when the user
  performing the action has no suitable 2fa method enabled. It receives the
  request params of the controller action. Return value is insignificant.

2. second_factor_auth_required!(params):
  This method corresponds to outcome (2a) above. It also receives the request
  params of the controller action. The purpose of this method is to keep track
  of the params that are needed to perform the action and where they should be
  redirected after the user completes the 2fa.

  To communicate this information to the auth manager, the return value of this
  method is utilized for this purpose. This method must return a Hash that
  should have 2 keys:

  :callback_params => another Hash containing the params that are needed to
  finish the action once 2fa is completed. Everything in this Hash must be
  serializable to JSON.

  :redirect_path => relative subfolder-aware path that the user should be
  redirected to after the action is finished. When this key is omitted, the
  redirect path is set to the homepage (/).

  After this method is called, the auth manager will send a 403 response with a
  JSON body. It does that by raising an exception that's then rescued by a
  `rescue_from` handler. The JSON response contains a challenge nonce which the
  client/frontend will need to complete the 2fa. More on this later.

3. second_factor_auth_completed!(callback_params):
  This method corresponds to outcome (2b) above. It's called after the user has
  successfully completed the 2fa for the 2fa-protected action and the purpose
  of this method is to actually perform that action.

  The `callback_params` param of this method is the `callback_params` Hash from
  the return value of the previous method.

If there are permission/security checks that the current user must pass in
order to perform the 2fa-protected action, it's important to run the checks in
all of the 3 methods of the action class and raise errors if the user doesn't
pass the checks.

Rendering a response to the client in the outcomes (1) and (2b) is a task for
the controller action. The return value of the `run_second_factor!` method,
which is an instance of `SecondFactor::AuthManagerResult`, can be used to know
which outcome the auth manager has picked and render a different response based
on the outcome.

For a real example where the auth manager is used, please refer to:

* `SecondFactor::Actions::GrantAdmin` action class. This is a class that
  inherits `SecondFactor::Actions::Base` and implements the 3 methods mentioned
  above.

* `Admin::UsersController#grant_admin` controller action.

=end

class SecondFactor::AuthManager
  MAX_CHALLENGE_AGE = 5.minutes

  class SecondFactorRequired < StandardError
    attr_reader :nonce

    def initialize(nonce:)
      @nonce = nonce
    end
  end

  attr_reader :allowed_methods

  def self.find_second_factor_challenge(nonce, secure_session)
    challenge_json = secure_session["current_second_factor_auth_challenge"]
    if challenge_json.blank?
      raise SecondFactor::BadChallenge.new(
        "second_factor_auth.challenge_not_found",
        status_code: 404
      )
    end

    challenge = JSON.parse(challenge_json).deep_symbolize_keys
    if challenge[:nonce] != nonce
      raise SecondFactor::BadChallenge.new(
        "second_factor_auth.challenge_not_found",
        status_code: 404
      )
    end

    generated_at = challenge[:generated_at]
    if generated_at < MAX_CHALLENGE_AGE.ago.to_i
      raise SecondFactor::BadChallenge.new(
        "second_factor_auth.challenge_expired",
        status_code: 401
      )
    end
    challenge
  end

  def initialize(guardian, action)
    @guardian = guardian
    @current_user = guardian.user
    @action = action
    @allowed_methods = Set.new([
      UserSecondFactor.methods[:totp],
      UserSecondFactor.methods[:security_key],
    ]).freeze
  end

  def allow_backup_codes!
    add_method(UserSecondFactor.methods[:backup_codes])
  end

  def run!(request, params, secure_session)
    if !allowed_methods.any? { |m| @current_user.valid_second_factor_method_for_user?(m) }
      @action.no_second_factors_enabled!(params)
      create_result(:no_second_factor)
    elsif nonce = params[:second_factor_nonce].presence
      verify_second_factor_auth_completed(nonce, secure_session)
      create_result(:second_factor_auth_completed)
    else
      nonce = initiate_second_factor_auth(params, secure_session, request)
      raise SecondFactorRequired.new(nonce: nonce)
    end
  end

  private

  def initiate_second_factor_auth(params, secure_session, request)
    config = @action.second_factor_auth_required!(params)
    nonce = SecureRandom.alphanumeric(32)
    callback_params = config[:callback_params] || {}
    redirect_path = config[:redirect_path] || GlobalPath.path("").presence || "/"
    challenge = {
      nonce: nonce,
      callback_method: request.request_method,
      callback_path: request.path,
      callback_params: callback_params,
      redirect_path: redirect_path,
      allowed_methods: allowed_methods.to_a,
      generated_at: Time.zone.now.to_i
    }
    secure_session["current_second_factor_auth_challenge"] = challenge.to_json
    nonce
  end

  def verify_second_factor_auth_completed(nonce, secure_session)
    challenge = self.class.find_second_factor_challenge(nonce, secure_session)
    if !challenge[:successful]
      raise SecondFactor::BadChallenge.new(
        "second_factor_auth.challenge_not_completed",
        status_code: 401
      )
    end

    secure_session["current_second_factor_auth_challenge"] = nil
    callback_params = challenge[:callback_params]
    @action.second_factor_auth_completed!(callback_params)
  end

  def add_method(id)
    if !@allowed_methods.include?(id)
      @allowed_methods = Set.new(@allowed_methods)
      @allowed_methods.add(id)
      @allowed_methods.freeze
    end
  end

  def create_result(status)
    SecondFactor::AuthManagerResult.new(status)
  end
end
