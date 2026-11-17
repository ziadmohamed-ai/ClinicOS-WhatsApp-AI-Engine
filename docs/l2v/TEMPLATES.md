# Lead-to-Visit (`l2v`) — Meta WhatsApp Templates

This document specifies the three Arabic WhatsApp message templates required by the Lead-to-Visit (`l2v`) add-on (`database/05_lead_engine.sql`).

Because staff notifications (`lead_handoff`, `sla_breach`, `sla_breach_no_rep`) are sent to reception reps and the clinic manager—who may not have messaged the clinic's WhatsApp number within the last 24 hours—`l2v._notify` calls `private.build_whatsapp_message(..., p_in_window => false)`. When the template names are configured in `public.clinics.settings.whatsapp_templates`, ClinicOS sends approved Meta **Template** messages; if a template name is missing or blank, it falls back to a plain-text message (which only delivers inside an open 24-hour customer service window).

---

## Meta Submission Summary

Submit all three templates in **Meta Business Suite → WhatsApp Manager → Message Templates** with the following settings:

| Template Key (`clinics.settings`) | Default Meta Template Name | Category | Language | Buttons |
| :--- | :--- | :--- | :--- | :--- |
| `lead_handoff` | `lead_handoff` | `UTILITY` | Arabic (`ar`) | 1 Quick-Reply button: `استلمت العميل` |
| `sla_breach` | `sla_breach` | `UTILITY` | Arabic (`ar`) | None |
| `sla_breach_no_rep` | `sla_breach_no_rep` | `UTILITY` | Arabic (`ar`) | None |

---

## 1. `lead_handoff` (New Hot Lead Assigned to Reception Rep)

Sent by `l2v.assign_lead` → `l2v._notify` when a lead qualifies as `hot` (`score >= 70`) or is reassigned to the next active rep on SLA escalation.

- **Meta Template Name:** `lead_handoff`
- **Category:** `UTILITY`
- **Language:** `ar`
- **Idempotency Key:** `'l2v:handoff:' || assignment_id`

### Exact Arabic Body Text

```text
عميل جديد جاهز للتواصل: {{1}} ({{2}}). تواصل معاه خلال {{3}} دقيقة وإلا هيتحوّل لزميلك.
```

*(Matches the fallback text in `database/05_lead_engine.sql`: `'عميل جديد جاهز للتواصل: ' || coalesce(nullif(v_lead.treatment_interest, ''), '-') || ' (' || v_phone || '). تواصل معاه خلال ' || v_sla || ' دقيقة وإلا هيتحوّل لزميلك.'`)*

### Exact Variable Order (`p_params`)

Passed by `l2v.assign_lead` as `array[coalesce(nullif(v_lead.treatment_interest, ''), '-'), v_phone, v_sla::text]` and mapped in array order by `private.build_whatsapp_message`:

| Placeholder | SQL Expression in `l2v.assign_lead` | Description | Example Value |
| :--- | :--- | :--- | :--- |
| `{{1}}` | `coalesce(nullif(v_lead.treatment_interest, ''), '-')` | Patient's treatment interest (`treatment_interest`, fallback `'-'`) | `تبييض الأسنان بالليزر` |
| `{{2}}` | `v_phone` (`contacts.phone_e164`) | Patient phone number in E.164 format (`phone_e164`) | `+201111111111` |
| `{{3}}` | `v_sla::text` (`l2v.settings.sla_minutes::text`) | SLA response window in minutes (`sla_minutes::text`) | `15` |

### Quick-Reply Button Configuration

- **Button Type:** Quick Reply (`QUICK_REPLY` / `sub_type: "quick_reply"`)
- **Button Index:** `0` (`"index": "0"`)
- **Button Text (Arabic):** `استلمت العميل`
- **Runtime Button Payload (`p_button_payload`):** `'l2v_ack:' || assignment_id`
  - Appended by `l2v._notify` to `payload.template.components` as:
    ```json
    {
      "type": "button",
      "sub_type": "quick_reply",
      "index": "0",
      "parameters": [
        {
          "type": "payload",
          "payload": "l2v_ack:<assignment_id>"
        }
      ]
    }
    ```
  - When the rep taps `استلمت العميل`, `L2V Gate` recognizes the staff phone via `l2v.is_staff` and calls `l2v.rep_ack(clinic_id, phone_e164)` to acknowledge the rep's oldest pending assignment without invoking the AI receptionist.

---

## 2. `sla_breach` (Manager Alert: Rep Missed SLA, Reassigned to Next Rep)

Sent by `l2v.escalate_overdue` → `l2v._notify` to `l2v.settings.manager_contact_id` when a pending assignment passes `sla_due_at` and is reassigned to another eligible active rep.

- **Meta Template Name:** `sla_breach`
- **Category:** `UTILITY`
- **Language:** `ar`
- **Buttons:** None (`p_button_payload = null`)
- **Idempotency Key:** `'l2v:breach:' || assignment_id`

### Exact Arabic Body Text

```text
تنبيه: {{1}} اتأخر على العميل {{2}} أكتر من {{3}} دقيقة، واتحوّل العميل لـ{{4}}.
```

*(Matches the fallback text in `database/05_lead_engine.sql`: `'تنبيه: ' || r.from_rep || ' اتأخر على العميل ' || r.lead_phone || ' أكتر من ' || r.sla_minutes || ' دقيقة، واتحوّل العميل لـ' || v_to_name || '.'`)*

### Exact Variable Order (`p_params`)

Passed by `l2v.escalate_overdue` as `array[r.from_rep, r.lead_phone, r.sla_minutes::text, v_to_name]`:

| Placeholder | SQL Expression in `l2v.escalate_overdue` | Description | Example Value |
| :--- | :--- | :--- | :--- |
| `{{1}}` | `r.from_rep` (`l2v.reps.name`) | Overdue rep name (`from_rep`) | `أحمد` |
| `{{2}}` | `r.lead_phone` (`contacts.phone_e164`) | Patient phone number in E.164 format (`lead_phone`) | `+201111111111` |
| `{{3}}` | `r.sla_minutes::text` (`coalesce(s.sla_minutes, 15)::text`) | SLA response window in minutes (`sla_minutes::text`) | `15` |
| `{{4}}` | `v_to_name` (`l2v.reps.name`) | Newly assigned rep name (`v_to_name`) | `محمد` |

---

## 3. `sla_breach_no_rep` (Manager Alert: All Reps Exhausted)

Sent by `l2v.escalate_overdue` → `l2v._notify` to `l2v.settings.manager_contact_id` when an assignment expires and no eligible active rep remains who has not already been assigned the lead (`v_new is null`).

- **Meta Template Name:** `sla_breach_no_rep`
- **Category:** `UTILITY`
- **Language:** `ar`
- **Buttons:** None (`p_button_payload = null`)
- **Idempotency Key:** `'l2v:breach:' || assignment_id`

### Exact Arabic Body Text

```text
تنبيه: العميل {{1}} ما اتسلّمش لأي موظف وكل الموظفين جرّبوا. محتاج تدخلك.
```

*(Matches the fallback text in `database/05_lead_engine.sql`: `'تنبيه: العميل ' || r.lead_phone || ' ما اتسلّمش لأي موظف وكل الموظفين جرّبوا. محتاج تدخلك.'`)*

### Exact Variable Order (`p_params`)

Passed by `l2v.escalate_overdue` as `array[r.lead_phone]`:

| Placeholder | SQL Expression in `l2v.escalate_overdue` | Description | Example Value |
| :--- | :--- | :--- | :--- |
| `{{1}}` | `r.lead_phone` (`contacts.phone_e164`) | Patient phone number in E.164 format (`lead_phone`) | `+201111111111` |

---

## `clinics.settings.whatsapp_templates` JSON Configuration

`private.build_whatsapp_message` looks up each template at `clinics.settings #> ARRAY['whatsapp_templates', p_template_key]`, reads `name`, and resolves the language code via `language_codes.ar` (defaulting to `'ar'`).

Merge the following object under `public.clinics.settings.whatsapp_templates` (or run `database/05b_l2v_seed_example.sql`):

```json
{
  "whatsapp_templates": {
    "lead_handoff": {
      "name": "lead_handoff",
      "language_codes": {
        "ar": "ar"
      }
    },
    "sla_breach": {
      "name": "sla_breach",
      "language_codes": {
        "ar": "ar"
      }
    },
    "sla_breach_no_rep": {
      "name": "sla_breach_no_rep",
      "language_codes": {
        "ar": "ar"
      }
    }
  }
}
```
