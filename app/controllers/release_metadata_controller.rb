class ReleaseMetadataController < SignedInApplicationController
  using RefinedString

  before_action :require_write_access!, only: %i[edit update]
  before_action :set_release, only: %i[edit update]
  before_action :ensure_editable

  def edit
    @train = @release.train
    @app = @train.app
    @release_metadata = @release.release_metadata
  end

  def update
    @metadata = ReleaseMetadata.find_or_initialize_by(train_run: @release)

    if @metadata.update(release_metadata_params)
      redirect_to release_path(@release), notice: "Release metadata was successfully updated."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  private

  def release_metadata_params
    params.require(:release_metadata).permit(
      :release_notes,
      :promo_text
    )
  end

  def set_release
    @release =
      Releases::Train::Run
        .joins(train: :app)
        .where(apps: {organization: current_organization})
        .find(params[:release_id])
  end

  def ensure_editable
    unless @release.metadata_editable?
      redirect_back fallback_location: release_path(@release),
        flash: {error: "Cannot update the release metadata once the production release has begun."}
    end
  end
end
