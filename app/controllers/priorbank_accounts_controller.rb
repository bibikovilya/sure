class PriorbankAccountsController < ApplicationController
  def link
    @priorbank_account = PriorbankAccount.find(params[:id])
    @available_accounts = Current.family.accounts
      .visible_manual
      .order(:name)

    render :link, layout: false
  end

  def link_account
    @priorbank_account = PriorbankAccount.find(params[:id])
    @account = Current.family.accounts.find(params[:priorbank_link][:account_id])

    # Guard: only manual accounts can be linked
    if @account.account_providers.any? || @account.plaid_account_id.present? || @account.simplefin_account_id.present?
      flash[:alert] = t(".errors.only_manual")
      if turbo_frame_request?
        return render turbo_stream: Array(flash_notification_stream_items)
      else
        return redirect_to accounts_path, alert: flash[:alert]
      end
    end

    # Verify the Priorbank account belongs to this family
    unless Current.family.priorbank_items.include?(@priorbank_account.priorbank_item)
      flash[:alert] = t(".errors.invalid_account")
      if turbo_frame_request?
        return render turbo_stream: Array(flash_notification_stream_items)
      else
        return redirect_to accounts_path, alert: flash[:alert]
      end
    end

    AccountProvider.create!(
      account: @account,
      provider: @priorbank_account
    )

    if turbo_frame_request?
      @priorbank_account.reload
      item = @priorbank_account.priorbank_item
      item.reload

      flash[:notice] = t(".success")

      render turbo_stream: [
        turbo_stream.replace(
          ActionView::RecordIdentifier.dom_id(item),
          partial: "priorbank_items/priorbank_item",
          locals: { priorbank_item: item }
        )
      ] + Array(flash_notification_stream_items)
    else
      redirect_to accounts_path, notice: t(".success"), status: :see_other
    end
  end
end
