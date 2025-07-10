import { action } from "@ember/object";
import Route from "@ember/routing/route";
import { service } from "@ember/service";
import { i18n } from "discourse-i18n";
import UserSubscription from "discourse/plugins/discourse-subscriptions/discourse/models/user-subscription";
import { popupAjaxError } from "discourse/lib/ajax-error";

export default class UserBillingSubscriptionsIndexRoute extends Route {
  @service dialog;
  @service router;

  model() {
    return UserSubscription.findAll();
  }

  @action
  cancelSubscription(subscription) {
    this.dialog.yesNoConfirm({
      message: i18n(
          "discourse_subscriptions.user.subscriptions.operations.destroy.confirm",
      ),
      didConfirm: () => {
        subscription.set("loading", true);
        subscription.destroy().then((result) => {
          subscription.setProperties({
            status: result.status,
            renews_at: result.renews_at
          });
        })
            .catch(popupAjaxError)
            .finally(() => subscription.set("loading", false));
      },
    });
  }
}
