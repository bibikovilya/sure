class PriorbankItemsController < ApplicationController
  before_action :set_priorbank_item, only: [ :destroy, :sync ]

  def create
    login = priorbank_params[:login]
    password = priorbank_params[:password]
    name = priorbank_params[:name].presence || "PriorBank Connection"

    return render_error(t(".errors.blank_credentials")) if login.blank? || password.blank?

    begin
      Current.family.priorbank_items.create!(name:, login:, password:)
      flash.now[:notice] = t(".success")
      render_providers_panel_stream
    rescue => e
      Rails.logger.error("Priorbank connection error: #{e.message}")
      render_error(t(".errors.unexpected", error: e.message))
    end
  end

  def destroy
    @priorbank_item.destroy_later
    flash.now[:notice] = t(".success")
    render_providers_panel_stream
  end

  def sync
    unless @priorbank_item.syncing?
      @priorbank_item.sync_later
    end

    respond_to do |format|
      format.html { redirect_back_or_to accounts_path }
      format.json { head :ok }
    end
  end

  private

    def set_priorbank_item
      @priorbank_item = Current.family.priorbank_items.find(params[:id])
    end

    def priorbank_params
      params.require(:priorbank_item).permit(:name, :login, :password)
    end

    def render_providers_panel_stream
      @priorbank_item = PriorbankItem.new
      @priorbank_items = Current.family.priorbank_items.ordered

      respond_to do |format|
        format.turbo_stream do
          render turbo_stream: [
            turbo_stream.replace(
              "priorbank-providers-panel",
              partial: "settings/providers/priorbank_panel"
            ), *flash_notification_stream_items
          ]
        end
      end
    end

    def render_error(message)
      @error_message = message

      render_providers_panel_stream
      response.status = :unprocessable_entity
    end
end
