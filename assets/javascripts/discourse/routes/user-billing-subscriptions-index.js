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
    return UserSubscription.findAll().then((result) => {
      // FIX: The data is nested inside a 'subscriptions' key.
      const subscriptions = result.subscriptions || [];
      return subscriptions.map((sub) => UserSubscription.create(sub));
    });
  }

  @action
  cancelSubscription(subscription) {
    this.dialog.yesNoConfirm({
      message: i18n(
          "discourse_subscriptions.user.subscriptions.operations.destroy.confirm"
      ),
      didConfirm: () => {
        subscription.set("loading", true);
        subscription.destroy()
            .then(updatedSubscription => {
              subscription.setProperties({
                status: updatedSubscription.status,
                renews_at: updatedSubscription.renews_at
              });
            })
            .catch(popupAjaxError)
            .finally(() => subscription.set("loading", false));
      },
    });
  }
}
