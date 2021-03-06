require 'json'
require 'digest/md5'
require 'net/http'
require 'nitro_api/challenge'
require 'nitro_api/rule'

module NitroApi
  HOST = "http://sandbox.bunchball.net/nitro/"
  ACCEPT = "json?"

  class NitroError < StandardError
    attr_accessor :code

    def initialize (err_code=nil)
      @code = err_code
    end
  end

  class NitroApi
    attr_accessor :session

    def initialize (user_id, api_key, secret)
      # Required Parameters
      @secret = secret
      @api_key = api_key
      @user = user_id
    end

    #  Method for constructing a signature
    def sign
      time = Time.now.utc.to_i.to_s
      unencrypted_signature = @api_key + @secret + time + @user.to_s
      to_digest = unencrypted_signature + unencrypted_signature.length.to_s
      return Digest::MD5.hexdigest(to_digest)
    end

    def login
      params = {
        :sig => sign,
        :ts => Time.now.utc.to_i.to_s,
        :apiKey => @api_key,
        :userId => @user,
        :method => 'user.login'
      }
      response = make_call(params)
      @session = response["Login"]["sessionKey"]
    end

    def log_action(actions, opts={})
      value = opts.delete(:value)
      user_id = opts.delete(:other_user)
      params = {
        :tags => actions.is_a?(Array) ? actions.join(",") : actions,
        :sessionKey => @session,
        :method => 'user.logAction'
      }
      params[:value] = value.to_s if value && !value.to_s.empty?
      params[:userId] = user_id if user_id && !user_id.to_s.empty
      make_call(params)
    end

    def challenge_progress(opts={})
      params = {
        :sessionKey => @session,
        :method => 'user.getChallengeProgress'
      }
      challenge = opts[:challenge]
      params['challengeName'] = challenge if challenge and !challenge.to_s.empty?
      params['showOnlyTrophies'] = opts.delete(:trophies_only) || false
      params['folder'] = opts.delete(:folder) if opts.has_key?(:folder)

      response = make_call(params)

      if valid_response?(response['challenges'])
        items = ensure_array(response['challenges']['Challenge'])
        items.reduce([]) do |challenges, item|
          challenge = Challenge.new
          challenge.name = item["name"]
          challenge.description = item["description"]
          challenge.full_url = item["fullUrl"]
          challenge.thumb_url = item["thumbUrl"]
          challenge.completed = item["completionCount"].to_i

          if valid_response?(item["rules"])
            ensure_array(item["rules"]['Rule']).each do |rule_elm|
              rule = Rule.new
              rule.action = rule_elm['actionTag']
              rule.type = rule_elm['type'].to_sym
              rule.completed = rule_elm['type'] == 'true'
              if rule_elm['goal'] && !rule_elm['goal'].empty?
                rule.goal = rule_elm['goal'].to_i
              end
              challenge.rules<< rule
            end
          end
          challenges<< challenge
        end
      end
    end

    def award_challenge(challenge)
      params = {
        :sessionKey => @session,
        :userId => @user,
        :method => 'user.awardChallenge',
        :challenge => challenge
      }
      make_call(params)
    end

    def action_history actions=[]
      params = {
        :sessionKey => @session,
        :method => 'user.getActionHistory'
      }
      if actions && !actions.empty?
        params[:tags] = actions.is_a?(Array) ? actions.join(",") : actions
      end
      response = make_call(params)
      if valid_response?(response['ActionHistoryRecord'])
        items = ensure_array(response['ActionHistoryRecord']['ActionHistoryItem'])
        items.reduce([]) do
          |history, item|
          history<< {:tags => item['tags'],
            :ts => Time.at(item['ts'].to_i),
            :value => item['value'].to_i
          }
        end
      else
        []
      end
    end

    def join_group group
      params = {
        :sessionKey => @session,
        :method => 'user.joinGroup',
        :groupName => group
      }
      make_call(params)
    end

    private

    def valid_response?(obj)
      obj.is_a?(Array) || obj.is_a?(Hash)
    end

    def ensure_array(items)
      items.is_a?(Array) ? items : [items]
    end

    def make_call(params)
      request = HOST + ACCEPT + to_query(params)
      data = Net::HTTP.get(URI.parse(request))
      json = JSON.parse(data)
      response = json["Nitro"]
      error = response["Error"]
      if error
        raise NitroError.new(error["Code"]), error["Message"]
      else
        response
      end
    end

    def to_query params
      URI.escape(params.map { |k,v| "#{k.to_s}=#{v.to_s}" }.join("&"))
    end
  end
end
