require 'pra/pull_source'
require 'pra/pull_request'
require 'pra/error_log'
require 'pra/log'
require 'json'
require 'faraday'

module Pra
  class GithubPullSource < Pra::PullSource
    def initialize(config = {})
      @ratelimit_remaining = 5000
      @ratelimit_limit = 5000
      @ratelimit_reset = nil
      super(config)
    end

    def pull_requests
      return get_all_pull_requests
    end

    def get_all_pull_requests
      pull_requests = []
      pull_requests_json = "[]"
      q_repos = ""
      @config['repositories'].each do |repo|
        if q_repos.empty?
          q_repos << "repo:#{repo['owner']}/#{repo['repository']}"
        else
          q_repos << " repo:#{repo['owner']}/#{repo['repository']}"
        end
      end

      conn = Faraday.new
      conn.basic_auth(@config['username'], @config['password'])
      resp = conn.get do |req|
        req.url rest_api_search_issues_url
        req.params['q'] = "is:pr is:open sort:updated-desc #{q_repos}"
        req.headers['Content-Type'] = 'application/json'
        req.headers['Accept'] = 'application/json'
      end

      @ratelimit_reset = Time.at(resp.headers['x-ratelimit-reset'].to_i)
      @ratelimit_limit = resp.headers['x-ratelimit-limit'].to_i
      @ratelimit_remaining = resp.headers['x-ratelimit-remaining'].to_i
      Pra::Log.log("fetched pull requests and updated ratelimit tracking")
      Pra::Log.log("Ratelimit Reset: #{@ratelimit_reset}")
      Pra::Log.log("Ratelimit Limit: #{@ratelimit_limit}")
      Pra::Log.log("Ratelimit Remaining: #{@ratelimit_remaining}")
      pull_requests_json = resp.body
      pull_requests_hash = JSON.parse(pull_requests_json)
      Pra::Log.log(pull_requests_hash.inspect)
      pull_requests_hash['items'].each do |request|
        begin
          pull_requests << Pra::PullRequest.new(title: request["title"],
                                           from_reference: "",
                                           to_reference: "",
                                           author: request["user"]["login"],
                                           assignee: request["assignee"] ? request["assignee"]["login"] : nil,
                                           link: request['html_url'],
                                           service_id: 'github',
                                           repository: extract_repository_from_html_url(request['html_url']))
        rescue StandardError => e
          Pra::Log.log("Error: #{e.to_s}")
          Pra::Log.log("Request: #{request.inspect}")
          Pra::ErrorLog.log(e)
        end
      end
      pull_requests
    end

    def extract_repository_from_html_url(html_url)
      /https:\/\/github.com\/\w+\/([\w-]+)/.match(html_url)
      return $1
    end

    def rest_api_search_issues_url
      "#{@config['protocol']}://#{@config['host']}/search/issues"
    end

    def repositories
      @config["repositories"]
    end

    def get_repo_pull_requests(repository_config)
      requests = []
      Pra::Log.log("get_repo_pull_requests - #{repository_config.inspect}")
      JSON.parse(rest_api_pull_request_resource(repository_config)).each do |request|
        begin
          requests << Pra::PullRequest.new(title: request["title"], from_reference: request["head"]["label"], to_reference: request["base"]["label"], author: request["user"]["login"], assignee: request["assignee"] ? request["assignee"]["login"] : nil, link: request['html_url'], service_id: 'github', repository: repository_config["repository"])
        rescue StandardError => e
          Pra::Log.log("Error: #{e.to_s}")
          Pra::Log.log("Request: #{request.inspect}")
          Pra::ErrorLog.log(e)
        end
      end
      return requests
    end

    def rest_api_pull_request_url(repository_config)
      "#{@config['protocol']}://#{@config['host']}/repos/#{repository_config["owner"]}/#{repository_config["repository"]}/pulls"
    end

    def rest_api_pull_request_resource(repository_config)
      pull_requests_json = "[]"
      if @ratelimit_remaining > 0
        Pra::Log.log("rest_api_pull_request_resource - fetching pull requests")
        conn = Faraday.new
        conn.basic_auth(@config['username'], @config['password'])
        resp = conn.get do |req|
          req.url rest_api_pull_request_url(repository_config)
          req.headers['Content-Type'] = 'application/json'
          req.headers['Accept'] = 'application/json'
        end

        @ratelimit_reset = Time.at(resp.headers['x-ratelimit-reset'].to_i)
        @ratelimit_limit = resp.headers['x-ratelimit-limit'].to_i
        @ratelimit_remaining = resp.headers['x-ratelimit-remaining'].to_i
        Pra::Log.log("fetched pull requests and updated ratelimit tracking")
        Pra::Log.log("Ratelimit Reset: #{@ratelimit_reset}")
        Pra::Log.log("Ratelimit Limit: #{@ratelimit_limit}")
        Pra::Log.log("Ratelimit Remaining: #{@ratelimit_remaining}")
        pull_requests_json = resp.body
      elsif Time.now.utc > @ratelimit_reset
        Pra::Log.log("rest_api_pull_request_resource - fetching pull requests")
        conn = Faraday.new
        conn.basic_auth(@config['username'], @config['password'])
        resp = conn.get do |req|
          req.url rest_api_pull_request_url(repository_config)
          req.headers['Content-Type'] = 'application/json'
          req.headers['Accept'] = 'application/json'
        end

        @ratelimit_reset = Time.at(resp.headers['x-ratelimit-reset'].to_i)
        @ratelimit_limit = resp.headers['x-ratelimit-limit'].to_i
        @ratelimit_remaining = resp.headers['x-ratelimit-remaining'].to_i
        Pra::Log.log("fetched pull requests and updated ratelimit tracking")
        Pra::Log.log("Ratelimit Reset: #{@ratelimit_reset}")
        Pra::Log.log("Ratelimit Limit: #{@ratelimit_limit}")
        Pra::Log.log("Ratelimit Remaining: #{@ratelimit_remaining}")
        pull_requests_json = resp.body
      else
        Pra::Log.log("Skipping request because of ratelimit")
        Pra::Log.log("Ratelimit Reset: #{@ratelimit_reset}")
        Pra::Log.log("Ratelimit Limit: #{@ratelimit_limit}")
        Pra::Log.log("Ratelimit Remaining: #{@ratelimit_remaining}")
      end

      return pull_requests_json
    end
  end
end
