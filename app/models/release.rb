# == Schema Information
#
# Table name: releases
#
#  id                        :uuid             not null, primary key
#  branch_name               :string           not null
#  completed_at              :datetime
#  hotfixed_from             :uuid
#  internal_notes            :jsonb
#  is_automatic              :boolean          default(FALSE)
#  is_v2                     :boolean          default(FALSE)
#  new_hotfix_branch         :boolean          default(FALSE)
#  notification_channel      :jsonb
#  original_release_version  :string
#  release_type              :string           not null
#  scheduled_at              :datetime
#  slug                      :string           indexed
#  status                    :string           not null
#  stopped_at                :datetime
#  tag_name                  :string
#  created_at                :datetime         not null
#  updated_at                :datetime         not null
#  approval_overridden_by_id :uuid             indexed
#  release_pilot_id          :uuid
#  train_id                  :uuid             not null, indexed
#
class Release < ApplicationRecord
  has_paper_trail
  extend FriendlyId
  include AASM
  include Passportable
  include Taggable
  include Versionable
  include Displayable
  include Linkable
  include Sanitizable

  using RefinedString

  self.implicit_order_column = :scheduled_at
  self.ignored_columns += ["release_version"]

  DEFAULT_INTERNAL_NOTES = {
    "ops" => [
      {"insert" => "Write your internal notes, task lists, or descriptions about the release. Interesting things you want to remember? \n\nJust "},
      {"attributes" => {"bold" => true}, "insert" => "stick"},
      {"insert" => " them here! ⚡️🚃🌈 \n"}
    ]
  }

  STAMPABLE_REASONS = %w[
    created
    release_branch_created
    version_bump_branch_created
    version_bump_no_changes
    version_changed
    approvals_overwritten
    finalizing
    pre_release_failed
    backmerge_failure
    tag_created
    vcs_release_created
    finalize_failed
    stopped
    finished
  ]
  STAMPABLE_REASONS.concat(%w[status_changed backmerge_pr_created pr_merged pull_request_not_mergeable post_release_pr_succeeded kickoff_pr_succeeded]) # TODO: deprecate this
  STATES = {
    created: "created",
    pre_release_started: "pre_release_started",
    pre_release_failed: "pre_release_failed",
    on_track: "on_track",
    post_release: "post_release",
    post_release_started: "post_release_started",
    post_release_failed: "post_release_failed",
    stopped: "stopped",
    finished: "finished",
    partially_finished: "partially_finished",
    stopped_after_partial_finish: "stopped_after_partial_finish"
  }
  FAILED_STATES = %w[post_release_failed]
  FINALIZE_STATES = %w[on_track post_release_failed partially_finished]
  TERMINAL_STATES = %w[stopped stopped_after_partial_finish finished]
  POST_RELEASE_STATES = %w[post_release_started post_release_failed]
  SECTIONS = {
    overview: {title: "Overview"},
    changeset_tracking: {title: "Changeset tracking"},
    internal_builds: {title: "Internal builds"},
    regression_testing: {title: "Regression testing"},
    release_candidate: {title: "Release candidate"},
    soak_period: {title: "Soak period"},
    notes: {title: "Notes"},
    screenshots: {title: "Screenshots"},
    approvals: {title: "Approvals"},
    app_submission: {title: "App submission"},
    rollout_to_users: {title: "Rollout"},
    wrap_up_automations: {title: "Automations"}
  }
  FULL_ROLLOUT_VALUE = BigDecimal("100")

  belongs_to :train
  belongs_to :hotfixed_from, class_name: "Release", optional: true, foreign_key: "hotfixed_from", inverse_of: :hotfixed_releases
  belongs_to :release_pilot, class_name: "Accounts::User", optional: true
  belongs_to :approval_overridden_by, class_name: "Accounts::User", optional: true
  has_one :scheduled_release, dependent: :destroy
  has_one :release_changelog, dependent: :destroy, inverse_of: :release
  has_many :release_platform_runs, -> { sequential }, dependent: :destroy, inverse_of: :release
  has_many :release_metadata, through: :release_platform_runs
  has_many :all_commits, -> { stability }, dependent: :destroy, inverse_of: :release, class_name: "Commit"
  has_many :pull_requests, dependent: :destroy, inverse_of: :release
  has_many :builds, through: :release_platform_runs
  has_many :build_queues, dependent: :destroy
  has_one :active_build_queue, -> { active }, class_name: "BuildQueue", inverse_of: :release, dependent: :destroy
  has_many :hotfixed_releases, class_name: "Release", inverse_of: :hotfixed_from, dependent: :destroy
  has_many :approval_items, -> { order(:created_at) }, inverse_of: :release, dependent: :destroy

  has_many :store_rollouts, through: :release_platform_runs
  has_many :store_submissions, through: :release_platform_runs
  has_many :pre_prod_releases, through: :release_platform_runs
  has_many :production_releases, through: :release_platform_runs
  has_many :production_store_rollouts, -> { production }, through: :release_platform_runs

  scope :completed, -> { where(status: TERMINAL_STATES) }
  scope :pending_release, -> { where.not(status: TERMINAL_STATES) }
  scope :released, -> { where(status: :finished).where.not(completed_at: nil) }
  scope :sequential, -> { order("releases.scheduled_at DESC") }

  enum :status, STATES
  enum :release_type, {hotfix: "hotfix", release: "release"}

  aasm safe_state_machine_params(with_lock: false) do
    state :created, initial: true
    state(*STATES.keys)

    event :start_pre_release_phase do
      transitions from: [:created, :pre_release_failed, :pre_release_started], to: :pre_release_started
    end

    event :fail_pre_release_phase do
      transitions from: :pre_release_started, to: :pre_release_failed
    end

    event :start do
      transitions from: [:created, :pre_release_started], to: :on_track
    end

    event :start_post_release_phase do
      transitions from: [:on_track, :post_release_failed, :partially_finished], to: :post_release_started
    end

    event :fail_post_release_phase do
      transitions from: :post_release_started, to: :post_release_failed
    end

    event :partially_finish do
      transitions from: :on_track, to: :partially_finished
    end

    event :stop do
      before { self.stopped_at = Time.current }
      transitions from: :partially_finished, to: :stopped_after_partial_finish
      transitions from: [:created, :on_track, :post_release_started, :post_release_failed, :pre_release_started, :pre_release_failed], to: :stopped
    end

    event :finish do
      before { self.completed_at = Time.current }
      transitions from: :post_release_started, to: :finished
    end
  end

  before_create :set_internal_notes
  after_create :create_platform_runs!
  after_create :create_build_queue!, if: -> { train.build_queue_enabled? }
  after_commit -> { Releases::CopyPreviousApprovalsJob.perform_async(id) }, on: :create, if: :copy_approvals_enabled?
  after_commit -> { create_stamp!(data: {version: original_release_version}) }, on: :create

  attr_accessor :hotfix_platform
  friendly_id :human_slug, use: :slugged

  delegate :versioning_strategy, :patch_version_bump_only, to: :train
  delegate :app, :vcs_provider, :release_platforms, :notify!, :continuous_backmerge?, :approvals_enabled?, :copy_approvals?, to: :train
  delegate :platform, :organization, :notification_provider, to: :app

  def set_notification_channel!(notification_channel)
    self.notification_channel = {
      id: notification_channel["id"],
      name: notification_channel["name"]
    }

    save!
  end

  def release_specific_channel_deep_link
    notification_provider.channel_deep_link(release_specific_channel_id) if release_specific_channel_id.present?
  end

  def release_specific_channel_name
    notification_channel&.fetch("name")
  end

  def release_specific_channel_id
    notification_channel&.fetch("id")
  end

  def pre_release_error_message
    last_error = passports.where(reason: :pre_release_failed, kind: :error).last
    last_error&.message
  end

  def copy_previous_approvals
    previous_release = train.previously_finished_release
    return if previous_release.blank?

    previous_release.approval_items.find_each do |approval_item|
      new_approval_item = approval_items.find_or_initialize_by(
        content: approval_item.content,
        author_id: approval_item.author_id
      )
      new_approval_item.approval_assignees = approval_item.approval_assignees.map do |approval_assignee|
        new_approval_item.approval_assignees.find_or_initialize_by(
          assignee_id: approval_assignee.assignee_id
        )
      end

      unless new_approval_item.save
        Rails.logger.error "Failed to save approval item: #{new_approval_item.errors.full_messages.join(", ")}"
        return false
      end
    end

    approval_items.present?
  end

  def self.pending_release?
    pending_release.exists?
  end

  def self.for_branch(branch_name) = find_by(branch_name:)

  def human_slug
    date = scheduled_at.strftime("%Y-%m-%d")
    %W[#{date}-#{Haikunator.haikunate(0)} #{date}-#{Haikunator.haikunate(1)} #{date}-#{Haikunator.haikunate(10)}]
  end

  def index_score
    return if hotfix?
    return unless finished?

    reldex_params = Queries::ReldexParameters.call(self)
    train.release_index&.score(**reldex_params)
  end

  def step_statuses
    Computations::Release::StepStatuses.call(self)
  end

  def unhealthy?
    release_platform_runs.any?(&:unhealthy?)
  end

  def show_health?
    return true if ongoing? || partially_finished?
    return true if finished? && release_platform_runs.any?(&:show_health?)
    false
  end

  def production_release_happened?
    release_platform_runs.all?(&:production_release_happened?)
  end

  def production_release_active?
    release_platform_runs.all?(&:production_release_active?)
  end

  def production_release_started?
    # TODO: check if the submission has been sent for review and not just the presence of the latest production release
    release_platform_runs.all? { |rpr| rpr.latest_production_release.present? }
  end

  def mid_release_backmerge_failure_count
    return 0 unless continuous_backmerge?
    all_commits.size - mid_release_back_merge_prs.size - 1
  end

  def mid_release_back_merge_prs
    pull_requests.mid_release.back_merge_type
  end

  def post_release_back_merge_prs
    pull_requests.post_release.back_merge_type
  end

  def pre_release_forward_merge_prs
    pull_requests.pre_release.forward_merge_type
  end

  def mid_release_stability_prs
    pull_requests.mid_release.stability_type
  end

  def pre_release?
    pre_release_started? || pre_release_failed?
  end

  def duration
    return unless finished?
    ActiveSupport::Duration.build(completed_at - scheduled_at)
  end

  def unmerged_commits
    all_commits.where(backmerge_failure: true)
  end

  def stability_commits
    all_commits.where.not(id: first_commit&.id)
  end

  def compare_url
    vcs_provider.compare_url(train.working_branch, release_branch)
  end

  def version_ahead?(platform_run)
    return false if self == platform_run.release
    release_version.to_semverish >= platform_run.release_version.to_semverish
  end

  def create_build_queue!
    build_queues.create!(scheduled_at: (Time.current + train.build_queue_wait_time), is_active: true)
  end

  def applied_commits
    return all_commits if active_build_queue.blank?
    all_commits.where.not(build_queue_id: active_build_queue.id).or(all_commits.where(build_queue_id: nil))
  end

  def last_applicable_commit
    return unless committable?
    applied_commits.reorder(timestamp: :desc).first
  end

  def committable?
    created? || pre_release_started? || on_track? || partially_finished?
  end

  def active?
    TERMINAL_STATES.exclude?(status)
  end

  def queue_commit?(commit)
    active_build_queue.present? && stability_commit?(commit)
  end

  def stability_commit?(commit)
    first_commit != commit
  end

  def end_time
    completed_at || stopped_at
  end

  def fetch_commit_log
    # release branch for a new release may not exist on vcs provider since pre-release job runs in parallel to fetch commit log job
    target_branch = train.working_branch

    if upcoming?
      ongoing_head = train.ongoing_release.first_commit
      source_commitish, from_ref = ongoing_head.commit_hash, ongoing_head.short_sha
    elsif hotfix?
      return if new_hotfix_branch? # there is no diff between the hotfixed from tag and the new hotfix release branch
      source_commitish = from_ref = hotfixed_from.end_ref
      target_branch = hotfixed_from.release_branch
    else
      source_commitish = from_ref = previous_release&.end_ref
    end

    return if source_commitish.blank?

    transaction do
      changelog = create_release_changelog!(from_ref:)
      raw_commit_log = vcs_provider.commit_log(source_commitish, target_branch)
      return if raw_commit_log.blank?
      commits_to_create = raw_commit_log.map do |commit_attrs|
        {
          author_email: commit_attrs["author_email"],
          author_login: commit_attrs["author_login"],
          author_name: commit_attrs["author_name"],
          commit_hash: commit_attrs["commit_hash"],
          message: commit_attrs["message"],
          parents: commit_attrs["parents"] || [],
          timestamp: commit_attrs["timestamp"],
          url: commit_attrs["url"],
          release_id: id,
          release_changelog_id: changelog.id
        }
      end
      # rubocop:disable Rails/SkipsModelValidations
      Commit.insert_all!(commits_to_create)
      # rubocop:enable Rails/SkipsModelValidations
    end
  end

  def end_ref
    tag_name || last_commit.short_sha
  end

  def release_version
    release_platform_runs.pluck(:release_version).map(&:to_semverish).max.to_s
  end

  def build_number
    builds.order(created_at: :desc).pick(:build_number)
  end

  alias_method :version_current, :release_version

  def release_branch
    branch_name
  end

  def release_diff
    changes_since_last_release = release_changelog&.commits&.commit_messages(true)
    changes_since_last_run = all_commits.commit_messages(true)
    combined = ((changes_since_last_run || []) + (changes_since_last_release || []))
    sanitize_commit_messages(combined)
      .map { |str| "- #{str}" }
      .join("\n")
  end

  def branch_url
    train.vcs_provider&.branch_url(release_branch)
  end

  def tag_url
    train.vcs_provider&.tag_url(tag_name)
  end

  def pull_requests_url(open = false)
    train.vcs_provider&.pull_requests_url(branch_name, open:)
  end

  def ready_to_be_finalized?
    release_platform_runs.all? { |prun| prun.finished? || prun.stopped? }
  end

  def live_release_link
    return if Rails.env.test?
    release_url(self, link_params)
  end

  def notification_params
    train.notification_params.merge(
      {
        release_branch: release_branch,
        release_branch_url: branch_url,
        release_url: live_release_link,
        release_version: release_version,
        is_release_unhealthy: unhealthy?,
        release_completed_at: completed_at,
        release_started_at: scheduled_at,
        final_ios_release_version: (ios_release_platform_run.release_version if ios_release_platform_run&.finished?),
        final_android_release_version: (android_release_platform_run.release_version if android_release_platform_run&.finished?),
        release_specific_channel_id:
      }
    )
  end

  def last_commit
    all_commits.last
  end

  def first_commit
    all_commits.first
  end

  def latest_commit_hash(sha_only: true)
    vcs_provider.branch_head_sha(release_branch, sha_only:)
  end

  def upcoming?
    train.upcoming_release == self
  end

  def ongoing?
    train.ongoing_release == self
  end

  def blocked_for_production_release?
    return true if upcoming? && !Flipper.enabled?(:temporary_unblock_upcoming, self)
    return true if ongoing? && train.hotfix_release.present?
    approvals_blocking?
  end

  def hotfix_with_new_branch?
    hotfix? && new_hotfix_branch?
  end

  def hotfix_with_existing_branch?
    hotfix? && !new_hotfix_branch?
  end

  def all_hotfixes
    query = <<~SQL.squish
              WITH RECURSIVE hotfix_tree AS (
          SELECT *
          FROM releases
          WHERE hotfixed_from = :id
          AND release_type = 'hotfix'
          UNION ALL
          SELECT r.*
          FROM releases r
          JOIN hotfix_tree h ON r.hotfixed_from = h.id
          WHERE r.release_type = 'hotfix'
      )
      SELECT *
      FROM hotfix_tree
      ORDER BY scheduled_at DESC;
    SQL

    Release.find_by_sql [query, {id: id}]
  end

  def active_languages
    release_platform_runs
      .map(&:release_metadata)
      .flatten
      .map(&:locale)
      .map { |locale_tag| AppStores::Localizable.supported_store_language(locale_tag) }
      .uniq
      .sort
  end

  def ios_release_platform_run
    release_platform_runs.find(&:ios?)
  end

  def android_release_platform_run
    release_platform_runs.find(&:android?)
  end

  def failure_anywhere?
    release_platform_runs.any?(&:failure?)
  end

  def previous_finished_releases
    train.releases.where(status: "finished").where.not(id: id).reorder(completed_at: :desc)
  end

  def previous_release
    base_conditions = previous_finished_releases
    return base_conditions.first if completed_at.blank?

    base_conditions
      .where(completed_at: ...completed_at)
      .first
  end

  def update_train_version!
    train.update!(version_current: release_version)
  end

  def override_approvals(who)
    return unless active?
    return unless approvals_enabled?
    return true if approvals_overridden?

    if who == release_pilot
      update(approval_overridden_by: who)
      event_stamp!(reason: :approvals_overwritten, kind: :notice)
    end
  end

  def approvals_overridden?
    approval_overridden_by.present?
  end

  def approvals_finished?
    approval_items.approved.size == approval_items.size
  end

  def approvals_blocking?
    !(approvals_overridden? || approvals_finished?)
  end

  def copy_approvals_enabled?
    copy_approvals? && release?
  end

  def copy_approvals_allowed?
    train.previously_finished_release.present? && !hotfix?
  end

  # either the previous release's end-of-release tag, or
  # it's the previous release's rollout tag
  def previous_tag_name
    prev = previous_release
    return if prev.blank?

    prev.tag_name.presence || prev.production_releases.last&.tag_name
  end

  private

  def base_tag_name
    tag = "v#{release_version}"
    tag = train.tag_end_of_release_prefix + "-" + tag if train.tag_end_of_release_prefix.present?
    tag += "-hotfix" if hotfix?
    tag += "-" + train.tag_end_of_release_suffix if train.tag_end_of_release_suffix.present?
    tag
  end

  def create_platform_runs!
    release_platforms.each do |release_platform|
      next if hotfix? && hotfix_platform.present? && hotfix_platform != release_platform.platform
      release_platform_runs.create!(
        status: ReleasePlatformRun::STATES[:created],
        code_name: Haikunator.haikunate(100),
        scheduled_at:,
        release_version: original_release_version,
        release_platform: release_platform
      )
    end
  end

  def set_internal_notes
    self.internal_notes = DEFAULT_INTERNAL_NOTES.to_json
  end
end
