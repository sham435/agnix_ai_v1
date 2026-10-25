# frozen_string_literal: true

require "rails_helper"

# rubocop:disable RSpec/ExampleLength, RSpec/MultipleExpectations

# Phase 2d — ScheduledTasksController. Proves authentication, strict
# current_user scoping (a user can never touch another user's task), and the
# create/pause/resume/destroy wiring. Generation itself is covered in RunJob
# specs; here we only assert the HTTP contract + ownership boundaries.
RSpec.describe "Scheduled tasks", type: :request do
  let(:organization) { create(:organization) }
  let(:user) { create(:user) }
  let(:agent) { create(:agent, organization: organization) }

  def sign_in_as(actor = user)
    create(:membership, user: actor, organization: organization) unless actor.organizations.include?(organization)
    api_login(actor)
  end

  # HTML form requests: carry the CSRF token but keep an HTML Accept (api_headers
  # forces application/json, which breaks `render :new` on validation failure).
  def form_headers
    { "X-CSRF-Token" => api_headers["X-CSRF-Token"] }
  end

  describe "authentication" do
    it "redirects an anonymous visitor to login" do
      get scheduled_tasks_path
      expect(response).to have_http_status(:redirect)
      expect(response).to redirect_to(login_path)
    end
  end

  describe "GET /scheduled" do
    before { sign_in_as }

    it "renders the inbox scoped to the current user" do
      create(:scheduled_task, user: user, agent: agent, organization: organization, name: "My digest")
      create(:scheduled_task, name: "Their secret") # different owner + org

      get scheduled_tasks_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("My digest")
      expect(response.body).not_to include("Their secret")
    end
  end

  describe "GET /scheduled/new" do
    before { sign_in_as }

    it "renders the creation form and prefills the prompt from ?prompt=" do
      get new_scheduled_task_path(prompt: "Draft a standup")
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Draft a standup")
    end
  end

  describe "POST /scheduled" do
    before { sign_in_as }

    it "creates a recurring task for the current user + organization" do
      expect do
        post scheduled_tasks_path, params: {
          scheduled_task: { name: "Daily", prompt: "Report", schedule_type: "recurring",
                            cron: "0 7 * * *", timezone: "Asia/Colombo", agent_id: agent.id }
        }, headers: form_headers
      end.to change { user.scheduled_tasks.count }.by(1)

      task = ScheduledTask.order(:created_at).last
      expect(task.organization).to eq(organization)
      expect(task).to be_active
      expect(task.next_run_at).to be_present
      expect(response).to redirect_to(scheduled_tasks_path)
    end

    it "creates a one-time task converting wall-clock time in its timezone" do
      expect do
        post scheduled_tasks_path, params: {
          scheduled_task: { name: "Once", prompt: "Ping", schedule_type: "one_time",
                            run_at_wall: "2026-11-01T07:00", timezone: "Asia/Colombo", agent_id: agent.id }
        }, headers: form_headers
      end.to change(ScheduledTask, :count).by(1)

      task = ScheduledTask.order(:created_at).last
      expect(task.run_at).to eq(Time.utc(2026, 11, 1, 1, 30, 0)) # 07:00 +0530
      expect(task.next_run_at).to eq(task.run_at)
    end

    it "rejects an agent outside the current organization" do
      foreign = create(:agent) # different org
      expect do
        post scheduled_tasks_path, params: {
          scheduled_task: { name: "Bad", prompt: "x", schedule_type: "recurring",
                            cron: "0 7 * * *", timezone: "UTC", agent_id: foreign.id }
        }, headers: form_headers
      end.not_to change(ScheduledTask, :count)
      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  describe "pause / resume" do
    let!(:task) do
      create(:scheduled_task, user: user, agent: agent, organization: organization,
                              cron: "0 7 * * *", timezone: "UTC")
    end

    before { sign_in_as }

    it "pauses a task and it drops out of the due queue" do
      post pause_scheduled_task_path(task), headers: form_headers
      expect(task.reload).to be_paused
      expect(ScheduledTask.due(Time.current).where(id: task.id)).to be_empty
    end

    it "resumes a task and recomputes a future next_run_at" do
      post pause_scheduled_task_path(task), headers: form_headers
      post resume_scheduled_task_path(task), headers: form_headers
      expect(task.reload).to be_active
      expect(task.next_run_at).to be > Time.current
    end

    it "does not let one user pause another user's task" do
      other = create(:scheduled_task, cron: "0 7 * * *", timezone: "UTC") # different owner
      post pause_scheduled_task_path(other), headers: form_headers
      expect(response).to redirect_to(scheduled_tasks_path)
      expect(other.reload).to be_active
    end
  end

  describe "DELETE /scheduled/:id" do
    before { sign_in_as }

    it "deletes the owner's task" do
      task = create(:scheduled_task, user: user, agent: agent, organization: organization)
      expect { delete scheduled_task_path(task), headers: form_headers }.to change(ScheduledTask, :count).by(-1)
    end
  end
end

# rubocop:enable RSpec/ExampleLength, RSpec/MultipleExpectations
