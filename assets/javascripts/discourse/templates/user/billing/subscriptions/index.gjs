import RouteTemplate from "ember-route-template";
import DButton from "discourse/components/d-button";
import loadingSpinner from "discourse/helpers/loading-spinner";
import routeAction from "discourse/helpers/route-action";
import { i18n } from "discourse-i18n";
import formatAbsoluteDate from "discourse/plugins/discourse-subscriptions/discourse/helpers/format-absolute-date";
import { and, eq, or, not } from "truth-helpers";

export default RouteTemplate(
<template>
  {{#if @controller.model.length}}
    <table class="table discourse-subscriptions-user-table">
      <thead>
      <th>{{i18n "discourse_subscriptions.user.plans.product"}}</th>
      <th>Plan</th>
      <th>Amount</th>
      <th>Status</th>
      <th>Provider</th>
      <th>Renews/Expires</th>
      <th></th>
      </thead>
      <tbody>
      {{#each @controller.model as |subscription|}}
        <tr class="subscription-row {{subscription.status}} {{if (eq subscription.status "revoked") "revoked-subscription"}}">
          <td>{{subscription.product_name}}</td>
          <td>{{subscription.plan_nickname}}</td>
          <td>{{subscription.amountDollars}}</td>
          <td><span class="status-badge">{{subscription.status}}</span></td>
          <td>{{subscription.provider}}</td>
          <td>
            {{#if subscription.renews_at}}
              {{formatAbsoluteDate subscription.renews_at}}
            {{else}}
              N/A
            {{/if}}
          </td>
          <td class="td-right">
            {{#if subscription.loading}}
              {{loadingSpinner size="small"}}
            {{else if (and (eq subscription.provider "Stripe") (eq subscription.plan_type "recurring"))}}
              <DButton
                  @disabled={{or (eq subscription.status "canceled") (eq subscription.status "revoked")}}
                  @action={{routeAction "cancelSubscription" subscription}}
                  @label="discourse_subscriptions.user.subscriptions.cancel"
                  class="btn-danger"
              />
            {{/if}}
          </td>
        </tr>
      {{/each}}
      </tbody>
    </table>
  {{else}}
    <div class="alert alert-info">
      {{i18n "discourse_subscriptions.user.subscriptions_help"}}
    </div>
  {{/if}}
</template>
);
