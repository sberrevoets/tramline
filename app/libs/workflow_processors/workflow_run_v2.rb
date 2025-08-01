class WorkflowProcessors::WorkflowRunV2
  include Memery
  GITHUB = WorkflowProcessors::Github::WorkflowRun
  BITRISE = WorkflowProcessors::Bitrise::WorkflowRun
  BITRISE_PIPELINE = WorkflowProcessors::Bitrise::PipelineRun
  BITBUCKET = WorkflowProcessors::Bitbucket::WorkflowRun
  GITLAB = WorkflowProcessors::Gitlab::WorkflowRun

  class WorkflowRunUnknownStatus < StandardError; end

  def self.process(workflow_run)
    new(workflow_run).process
  end

  def initialize(workflow_run)
    @workflow_run = workflow_run
  end

  def process
    return re_enqueue if in_progress?
    update_status!
  end

  private

  def re_enqueue
    WorkflowRuns::PollRunStatusJob.set(wait: wait_time).perform_async(workflow_run.id)
  end

  attr_reader :workflow_run
  delegate :in_progress?, :successful?, :failed?, :error?, :halted?, :artifacts_url, :started_at, :finished_at, to: :runner
  delegate :github_integration?, :bitrise_integration?, :bitbucket_integration?, :gitlab_integration?, to: :integration
  delegate :artifact_name_pattern, :app, to: :workflow_run

  def update_status!
    if successful?
      workflow_run.add_metadata!(artifacts_url:, started_at:, finished_at:)
      workflow_run.finish!
    elsif error? && workflow_run.allow_error?
      workflow_run.add_metadata!(artifacts_url:, started_at:, finished_at:)
      workflow_run.finish!
    elsif error?
      workflow_run.fail!
    elsif failed?
      workflow_run.fail!
    elsif halted?
      workflow_run.halt!
    else
      raise WorkflowRunUnknownStatus
    end
  end

  memoize def runner
    return GITHUB.new(external_workflow_run) if github_integration?
    return BITRISE_PIPELINE.new(external_workflow_run) if bitrise_integration? && app.custom_bitrise_pipelines?
    return BITRISE.new(workflow_run.ci_cd_provider, external_workflow_run, artifact_name_pattern) if bitrise_integration?
    return BITBUCKET.new(external_workflow_run) if bitbucket_integration?
    GITLAB.new(workflow_run.ci_cd_provider, external_workflow_run) if gitlab_integration?
  end

  def integration
    workflow_run.ci_cd_provider.integration
  end

  def external_workflow_run
    workflow_run.get_external_run
  end

  def wait_time
    if Rails.env.development?
      1.minute
    else
      2.minutes
    end
  end
end
