# == Schema Information
#
# Table name: github_integrations
#
#  id              :uuid             not null, primary key
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#  installation_id :string           not null
#
class GithubIntegration < ApplicationRecord
  has_paper_trail

  include Vaultable
  include Providable
  include Displayable
  include Rails.application.routes.url_helpers
  using RefinedHash

  validates :installation_id, presence: true

  delegate :code_repository_name, :code_repo_namespace, :code_repo_name_only, to: :app_config
  delegate :integrable, to: :integration
  delegate :organization, to: :integrable
  delegate :cache, to: Rails

  BASE_INSTALLATION_URL =
    Addressable::Template.new("https://github.com/apps/{app_name}/installations/new{?params*}")
  PUBLIC_ICON = "https://storage.googleapis.com/tramline-public-assets/github-small.png".freeze

  API = Installations::Github::Api

  REPOS_TRANSFORMATIONS = {
    id: :id,
    name: :name,
    namespace: [:owner, :login],
    full_name: :full_name,
    description: :description,
    repo_url: :html_url,
    avatar_url: [:owner, :avatar_url]
  }

  WORKFLOWS_TRANSFORMATIONS = {
    id: :id,
    name: :name
  }

  WORKFLOW_RUN_TRANSFORMATIONS = {
    ci_ref: :id,
    ci_link: :html_url,
    number: :run_number,
    unique_number: :run_number
  }

  INSTALLATION_TRANSFORMATIONS = {
    id: :id,
    account_name: [:account, :login],
    account_id: [:account, :id],
    avatar_url: [:account, :avatar_url]
  }

  COMMITS_TRANSFORMATIONS = {
    url: :html_url,
    commit_hash: :sha,
    message: [:commit, :message],
    author_name: [:commit, :author, :name],
    author_email: [:commit, :author, :email],
    author_login: [:author, :login],
    author_url: [:author, :html_url],
    timestamp: [:commit, :author, :date],
    parents: [:parents]
  }

  COMMITS_HOOK_TRANSFORMATIONS = {
    url: :url,
    commit_hash: :id,
    message: :message,
    author_name: [:author, :name],
    author_email: [:author, :email],
    author_login: [:author, :username],
    timestamp: :timestamp
  }

  PR_TRANSFORMATIONS = {
    source_id: :id,
    number: :number,
    title: :title,
    body: :body,
    url: :html_url,
    state: :state,
    head_ref: [:head, :ref],
    base_ref: [:base, :ref],
    opened_at: :created_at,
    closed_at: :closed_at,
    merge_commit_sha: :merge_commit_sha,
    labels: {
      labels: {
        id: :id,
        name: :name,
        color: :color,
        description: :description
      }
    }
  }

  ARTIFACTS_TRANSFORMATIONS = {
    id: :id,
    name: :name,
    size_in_bytes: :size_in_bytes,
    archive_download_url: :archive_download_url,
    generated_at: :created_at
  }

  def install_path
    BASE_INSTALLATION_URL
      .expand(app_name: creds.integrations.github.app_name, params: {
        state: integration.installation_state
      }).to_s
  end

  def workspaces = nil

  def repos(_)
    installation.list_repos(REPOS_TRANSFORMATIONS)
  end

  WEBHOOK_TRANSFORMATIONS = {
    id: :id,
    events: :events,
    url: [:config, :url]
  }

  def find_or_create_webhook!(id:, train_id:)
    GitHub::Result.new do
      if id
        webhook = installation.find_webhook(code_repository_name, id, WEBHOOK_TRANSFORMATIONS)
        if webhook[:url] == events_url(train_id:) && (installation.class::WEBHOOK_EVENTS - webhook[:events]).empty?
          webhook
        else
          update_webhook!(webhook[:id], train_id:)
        end
      else
        create_webhook!(train_id:)
      end
    rescue Installations::Error => ex
      raise ex unless ex.reason == :not_found
      create_webhook!(train_id:)
    end
  end

  def create_release!(tag_name, branch, previous_tag_name, release_notes)
    installation.create_release!(code_repository_name, tag_name, branch, previous_tag_name, release_notes)
  end

  def create_tag!(tag_name, sha)
    installation.create_tag!(code_repository_name, tag_name, sha)
  end

  def create_branch!(from, to, source_type: :branch)
    installation.create_branch!(code_repository_name, from, to, source_type:)
  end

  def pull_requests_url(branch_name, open: false)
    query_string = "is:pr base:#{branch_name}"
    query_string += " is:open" if open
    q = URI.encode_www_form("q" => query_string)
    "https://github.com/#{code_repository_name}/pulls?#{q}"
  end

  def branch_url(branch_name)
    "https://github.com/#{code_repository_name}/tree/#{branch_name}"
  end

  def tag_url(tag_name)
    "https://github.com/#{code_repository_name}/releases/tag/#{tag_name}"
  end

  def compare_url(to_branch, from_branch)
    "https://github.com/#{code_repository_name}/compare/#{to_branch}..#{from_branch}"
  end

  def pr_url(pr_number)
    "https://github.com/#{code_repository_name}/pull/#{pr_number}"
  end

  def installation
    API.new(installation_id)
  end

  def project_link = nil

  def to_s
    "github"
  end

  def creatable?
    false
  end

  def connectable?
    true
  end

  def store?
    false
  end

  def further_setup?
    false
  end

  def enable_auto_merge? = true

  def connection_data
    return unless integration.metadata
    "Organization: #{integration.metadata["account_name"]} (#{integration.metadata["account_id"]})"
  end

  def metadata
    installation.get_installation(installation_id, INSTALLATION_TRANSFORMATIONS)
  end

  def bot_name
    "#{creds.integrations.github.app_name}[bot]"
  end

  def pr_closed?(pr)
    pr[:state] == "closed"
  end

  def pr_open?(pr)
    pr[:state] == "open"
  end

  ## CI/CD

  def workflows(_ = nil, bust_cache: false)
    Rails.cache.delete(workflows_cache_key) if bust_cache

    cache.fetch(workflows_cache_key, expires_in: 120.minutes) do
      installation.list_workflows(code_repository_name, WORKFLOWS_TRANSFORMATIONS)
    end
  end

  def trigger_workflow_run!(ci_cd_channel, branch_name, inputs, commit_hash = nil, deploy_action_enabled = false)
    installation.run_workflow!(code_repository_name, ci_cd_channel, branch_name, inputs, commit_hash, deploy_action_enabled)
  end

  def cancel_workflow_run!(ci_ref)
    installation.cancel_workflow!(code_repository_name, ci_ref)
  end

  def retry_workflow_run!(ci_ref)
    installation.retry_workflow!(code_repository_name, ci_ref)
  end

  def find_workflow_run(workflow_id, branch, commit_sha)
    installation.find_workflow_run(code_repository_name, workflow_id, branch, commit_sha, WORKFLOW_RUN_TRANSFORMATIONS)
  end

  def get_workflow_run(workflow_run_id)
    installation.get_workflow_run(code_repository_name, workflow_run_id)
  end

  def artifact_url
    raise Integration::UnsupportedAction
  end

  # we currently only select the largest artifact from github, since we have no information about the file types
  # in the future, this could be smarter and/or a user input
  def get_artifact(artifacts_url, artifact_name_pattern, _)
    raise Installations::Error.new("Could not find the artifact", reason: :artifact_not_found) if artifacts_url.blank?

    artifact =
      installation
        .artifacts(artifacts_url, ARTIFACTS_TRANSFORMATIONS)
        .then { |artifacts| API.filter_by_name(artifacts, artifact_name_pattern) }
        .then { |artifacts| API.find_biggest(artifacts) }
        .tap { |artifact| raise Installations::Error.new("Could not find the artifact", reason: :artifact_not_found) if artifact.blank? }

    artifact_stream =
      installation
        .artifact_download_url(artifact)
        .then { |url| installation.artifact_io_stream(url) }
        .then { |zip_file| Artifacts::Stream.new(zip_file, is_archive: true) }

    {artifact:, stream: artifact_stream}
  end

  def branch_exists?(branch_name)
    installation.branch_exists?(code_repository_name, branch_name)
  rescue Installations::Error => ex
    raise ex unless ex.reason == :not_found
    false
  end

  def tag_exists?(tag_name)
    installation.tag_exists?(code_repository_name, tag_name)
  rescue Installations::Error => ex
    raise ex unless ex.reason == :not_found
    false
  end

  def create_pr!(to_branch_ref, from_branch_ref, title, description)
    from = namespaced_branch(from_branch_ref)
    installation.create_pr!(code_repository_name, to_branch_ref, from, title, description, PR_TRANSFORMATIONS).merge_if_present(source: :github)
  end

  def create_patch_pr!(to_branch, patch_branch, commit_hash, pr_title, pr_description)
    installation.cherry_pick_pr(code_repository_name, to_branch, commit_hash, patch_branch, pr_title, pr_description, PR_TRANSFORMATIONS).merge_if_present(source: :github)
  end

  def enable_auto_merge!(pr_number)
    installation.enable_auto_merge(code_repo_namespace, code_repo_name_only, pr_number)
  end

  def find_pr(to_branch_ref, from_branch_ref)
    from = namespaced_branch(from_branch_ref)
    installation.find_pr(code_repository_name, to_branch_ref, from, PR_TRANSFORMATIONS).merge_if_present(source: :github)
  end

  def get_pr(pr_number)
    installation.get_pr(code_repository_name, pr_number, PR_TRANSFORMATIONS).merge_if_present(source: :github)
  end

  def merge_pr!(pr_number)
    installation.merge_pr!(code_repository_name, pr_number, PR_TRANSFORMATIONS).merge_if_present(source: :github)
  end

  def commit_log(from_branch, to_branch)
    installation.commits_between(code_repository_name, from_branch, to_branch, COMMITS_TRANSFORMATIONS)
  end

  def get_commit(commit_hash)
    installation.get_commit(code_repository_name, commit_hash, COMMITS_TRANSFORMATIONS)
  end

  def diff_between?(from_branch, to_branch, _)
    installation.diff?(code_repository_name, from_branch, to_branch)
  rescue Installations::Error => ex
    raise ex unless ex.reason == :not_found
    true
  end

  def public_icon_img
    PUBLIC_ICON
  end

  def workflow_retriable? = false

  def workflow_retriable_in_place? = true

  def branch_head_sha(branch, sha_only: true)
    installation.head(code_repository_name, branch, sha_only:, commit_transforms: COMMITS_TRANSFORMATIONS)
  end

  def get_file_content(branch_name, file_path)
    installation.get_file_content(code_repository_name, branch_name, file_path)
  end

  def update_file!(branch_name, file_path, content, commit_message, author_name: nil, author_email: nil)
    installation.update_file!(code_repository_name, branch_name, file_path, content, commit_message, author_name:, author_email:)
  end

  private

  def namespaced_branch(branch_name)
    [code_repo_namespace, ":", branch_name].join
  end

  def create_webhook!(url_params)
    installation.create_repo_webhook!(code_repository_name, events_url(url_params), WEBHOOK_TRANSFORMATIONS)
  end

  def update_webhook!(id, url_params)
    installation.update_repo_webhook!(code_repository_name, id, events_url(url_params), WEBHOOK_TRANSFORMATIONS)
  end

  def app_config
    integrable.config
  end

  def events_url(params)
    if Rails.env.development?
      github_events_url(host: ENV["WEBHOOK_HOST_NAME"], **params)
    else
      github_events_url(host: ENV["HOST_NAME"], protocol: "https", **params)
    end
  end

  def workflows_cache_key
    "app/#{integrable.id}/github_integration/#{id}/workflows"
  end
end
