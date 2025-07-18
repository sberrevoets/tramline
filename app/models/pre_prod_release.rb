# == Schema Information
#
# Table name: pre_prod_releases
#
#  id                         :uuid             not null, primary key
#  config                     :jsonb            not null
#  status                     :string           default("created"), not null
#  tester_notes               :text
#  type                       :string           not null, indexed => [release_platform_run_id, commit_id]
#  created_at                 :datetime         not null
#  updated_at                 :datetime         not null
#  commit_id                  :uuid             not null, indexed => [release_platform_run_id, type], indexed
#  parent_internal_release_id :uuid             indexed
#  previous_id                :uuid             indexed
#  release_platform_run_id    :uuid             not null, indexed => [commit_id, type], indexed
#
class PreProdRelease < ApplicationRecord
  has_paper_trail
  include AASM
  include Loggable
  include Displayable
  include Passportable
  include Sanitizable

  belongs_to :release_platform_run
  belongs_to :previous, class_name: "PreProdRelease", inverse_of: :next, optional: true
  belongs_to :commit
  has_one :next, class_name: "PreProdRelease", inverse_of: :previous, dependent: :nullify
  has_one :triggered_workflow_run, class_name: "WorkflowRun", dependent: :destroy, inverse_of: :triggering_release
  has_many :store_submissions, -> { sequential }, as: :parent_release, dependent: :destroy, inverse_of: :parent_release

  scope :inactive, -> { where(status: INACTIVE) }

  before_create :set_default_tester_notes

  after_create_commit -> { previous&.mark_as_stale! }
  after_create_commit -> { create_stamp!(data: stamp_data) }

  delegate :release, :train, :platform, to: :release_platform_run
  delegate :notify!, :notify_with_snippet!, :notify_with_changelog!, to: :train

  alias_method :workflow_run, :triggered_workflow_run

  STATES = {
    created: "created",
    failed: "failed",
    stale: "stale",
    finished: "finished"
  }
  INACTIVE = STATES.values - ["created"]

  enum :status, STATES

  def failure?
    failed? || triggered_workflow_run.failure? || store_submissions.last&.failed?
  end

  def mark_as_stale!
    with_lock do
      return if finished?
      update!(status: STATES[:stale])
    end
  end

  def fail!
    update!(status: STATES[:failed])
    on_fail!
  end

  def actionable?
    created? && release_platform_run.on_track?
  end

  def build
    workflow_run&.build
  end

  def production? = false

  def trigger_submissions!
    return unless actionable?
    return finish! if conf.submissions.blank?
    trigger_submission!(conf.first_submission)
  end

  def rollout_started!
    # do something here, do we need to?
  end

  def rollout_complete!(submission)
    return unless actionable?

    next_submission_config = conf.fetch_submission_by_number(submission.sequence_number + 1)
    if next_submission_config
      trigger_submission!(next_submission_config)
    else
      finish!
    end
  end

  def conf = Config::ReleaseStep.from_json(config)

  def commits_since_previous
    commits_since_last_release = release.release_changelog&.commits || []
    last_successful_run = previous_successful
    commits_since_last_run = release.all_commits.between_commits(last_successful_run&.commit, commit) || []

    if last_successful_run
      commits_since_last_run
    else
      (commits_since_last_run + commits_since_last_release).uniq { |c| c.commit_hash }
    end
  end

  def changes_since_previous(skip_delta: false)
    changes_since_last_release = release.release_changelog&.commits&.commit_messages(true) || []
    last_successful_run = previous_successful
    changes_since_last_run = release.all_commits.between_commits(last_successful_run&.commit, commit)&.commit_messages(true) || []

    # always return the changelog + all changes until now
    if skip_delta
      new_changes_till_now = release.all_commits.between_commits(nil, commit)&.commit_messages(true) || []
      return (new_changes_till_now + changes_since_last_release).uniq
    end

    if last_successful_run
      changes_since_last_run
    else
      (changes_since_last_run + changes_since_last_release).uniq
    end
  end

  # NOTES: This logic should simplify once we allow users to edit the tester notes
  def generate_tester_notes(changes)
    sanitized_messages = sanitize_commit_messages(changes, compact_messages: train.compact_build_notes?)
    sanitized_messages
      .map { |str| "• #{str}" }
      .join("\n").presence || "Nothing new"
  end

  def set_default_tester_notes
    self.tester_notes = generate_tester_notes(changes_since_previous)
  end

  def previous_successful
    return if previous.blank?
    return previous if previous.finished?
    previous.previous_successful
  end

  def new_commit_available?
    return unless release_platform_run.on_track?
    return if release.last_applicable_commit.blank?
    release.last_applicable_commit != commit
  end

  def stamp_data
    {
      commit_sha: commit.short_sha,
      commit_url: commit.url
    }
  end

  def notification_params
    release_platform_run.notification_params.merge(
      commit_sha: commit.short_sha,
      commit_url: commit.url,
      build_number: build.build_number,
      release_version: release.release_version,
      submissions: store_submissions,
      first_pre_prod_release: previous_successful.blank?,
      diff_changelog: sanitize_commit_messages(changes_since_previous),
      full_changelog: sanitize_commit_messages(changes_since_previous(skip_delta: true))
    )
  end

  def latest_events(n = nil)
    stampable_id = [
      id,
      triggered_workflow_run.id,
      store_submissions.pluck(:id)
    ].compact.flatten

    Passport.where(stampable_id:).order(event_timestamp: :desc).limit(n)
  end

  private

  def trigger_submission!(submission_config)
    submission_config.submission_class.create_and_trigger!(self, submission_config, build)
  end
end
