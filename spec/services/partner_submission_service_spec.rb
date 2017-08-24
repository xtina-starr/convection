require 'rails_helper'
require 'support/gravity_helper'

describe PartnerSubmissionService do
  before do
    stub_gravity_root
    stub_gravity_user
    stub_gravity_user_detail
    stub_gravity_artist
  end

  describe '#generate_for_new_partner' do
    it 'generates partner submissions if the partner has no existing partner submissions' do
      submission = Fabricate(:submission, state: 'approved')
      Fabricate(:submission, state: 'submitted')
      partner = Fabricate(:partner)
      PartnerSubmissionService.generate_for_new_partner(partner)
      expect(partner.partner_submissions.count).to eq 1
      expect(PartnerSubmission.where(submission: submission, partner: partner).count).to eq 1
    end
    it 'generates new partner submissions' do
      partner = Fabricate(:partner)
      submission = Fabricate(:submission, state: 'submitted', user_id: 'userid', artist_id: 'artistid')
      SubmissionService.update_submission(submission, state: 'approved')
      expect(PartnerSubmission.where(submission: submission, partner: partner).count).to eq 1
      Fabricate(:submission, state: 'approved')
      PartnerSubmissionService.generate_for_new_partner(partner)
      expect(partner.partner_submissions.count).to eq 2
    end
  end

  describe '#generate_for_all_partners' do
    it 'generates a new partner submission for a single partner' do
      submission = Fabricate(:submission, state: 'approved')
      partner = Fabricate(:partner)
      PartnerSubmissionService.generate_for_all_partners(submission.id)
      expect(partner.partner_submissions.count).to eq 1
    end

    it 'does nothing if there are no partners' do
      submission = Fabricate(:submission, state: 'approved')
      expect { PartnerSubmissionService.generate_for_all_partners(submission.id) }.to_not change(PartnerSubmission, :count)
    end
  end

  describe '#daily_batch' do
    before do
      stub_gravity_partner(name: 'Juliens Auctions')
      allow(Convection.config).to receive(:consignment_communication_id).and_return('comm1')
    end

    it 'does not send any emails if there are no partner submissions' do
      Fabricate(:partner, gravity_partner_id: 'partnerid')
      Fabricate(:submission, state: 'approved')
      PartnerSubmissionService.daily_batch
      expect(PartnerSubmission.count).to eq 0
      emails = ActionMailer::Base.deliveries
      expect(emails.length).to eq 0
    end

    it 'does not send any emails if there are no partners' do
      Fabricate(:submission, state: 'approved')
      PartnerSubmissionService.daily_batch
      expect(PartnerSubmission.count).to eq 0
      emails = ActionMailer::Base.deliveries
      expect(emails.length).to eq 0
    end

    context 'with some submissions' do
      before do
        @partner = Fabricate(:partner, gravity_partner_id: 'partnerid')
        Fabricate(:submission, state: 'submitted')
        @approved1 = Fabricate(:submission,
          state: 'submitted',
          artist_id: 'artistid',
          user_id: 'userid',
          title: 'First approved artwork',
          year: '1992')
        @approved2 = Fabricate(:submission,
          state: 'submitted',
          artist_id: 'artistid',
          user_id: 'userid',
          title: 'Second approved artwork',
          year: '1993')
        @approved3 = Fabricate(:submission,
          state: 'submitted',
          artist_id: 'artistid',
          user_id: 'userid',
          title: 'Third approved artwork',
          year: '1997')
        Fabricate(:submission, state: 'rejected')
        SubmissionService.update_submission(@approved1, state: 'approved')
        SubmissionService.update_submission(@approved2, state: 'approved')
        SubmissionService.update_submission(@approved3, state: 'approved')
        ActionMailer::Base.deliveries = []
        expect(@partner.partner_submissions.count).to eq 3
      end

      context 'with no partner contacts' do
        before do
          stub_gravity_partner_contacts(override_body: [])
        end

        it 'skips sending to partner if there are no partner contacts' do
          PartnerSubmissionService.daily_batch
          emails = ActionMailer::Base.deliveries
          expect(emails.length).to eq 0
          expect(PartnerSubmission.all.map(&:notified_at).compact).to eq []
        end
      end

      context 'with some partner contacts' do
        before do
          stub_gravity_partner_contacts
        end

        it 'sends an email batch to a single partner with only approved submissions' do
          PartnerSubmissionService.daily_batch

          emails = ActionMailer::Base.deliveries
          expect(emails.length).to eq 1
          email = emails.first
          expect(email.subject).to include('Artsy Submission Batch for: Juliens Auctions')
          expect(email.html_part.body).to include('<i>First approved artwork</i><span>, 1992</span>')
          expect(email.html_part.body).to include('<i>Second approved artwork</i><span>, 1993</span>')
          expect(email.html_part.body).to include('<i>Third approved artwork</i><span>, 1997</span>')
          expect(@partner.partner_submissions.map(&:notified_at).compact.length).to eq 3
        end

        it 'sends an email batch to multiple partners' do
          partner2 = Fabricate(:partner, gravity_partner_id: 'phillips')
          PartnerSubmissionService.generate_for_new_partner(partner2)
          stub_gravity_partner(name: 'Phillips Auctions', id: 'phillips')
          stub_gravity_partner_contacts(partner_id: 'phillips')
          PartnerSubmissionService.daily_batch

          expect(@approved1.partner_submissions.count).to eq 2
          expect(@approved2.partner_submissions.count).to eq 2
          expect(@approved3.partner_submissions.count).to eq 2
          expect(@partner.partner_submissions.count).to eq 3
          expect(partner2.partner_submissions.count).to eq 3

          emails = ActionMailer::Base.deliveries
          expect(emails.length).to eq 2
          email = emails.first
          expect(email.html_part.body).to include('<i>First approved artwork</i><span>, 1992</span>')
          expect(email.html_part.body).to include('<i>Second approved artwork</i><span>, 1993</span>')
          expect(email.html_part.body).to include('<i>Third approved artwork</i><span>, 1997</span>')
        end

        it 'sends to only one partner if only one has partner contacts' do
          contactless_partner = Fabricate(:partner, gravity_partner_id: 'phillips')
          stub_gravity_partner(name: 'Phillips Auctions', id: 'phillips')
          stub_gravity_partner_contacts(partner_id: 'phillips', override_body: [])
          PartnerSubmissionService.daily_batch

          expect(@approved1.partner_submissions.count).to eq 1
          expect(@approved2.partner_submissions.count).to eq 1
          expect(@approved3.partner_submissions.count).to eq 1
          expect(contactless_partner.partner_submissions.count).to eq 0
          expect(@partner.partner_submissions.count).to eq 3

          emails = ActionMailer::Base.deliveries
          expect(emails.length).to eq 1
          email = emails.first
          expect(email.subject).to include('Artsy Submission Batch for: Juliens Auctions')
          expect(email.html_part.body).to include('<i>First approved artwork</i><span>, 1992</span>')
          expect(email.html_part.body).to include('<i>Second approved artwork</i><span>, 1993</span>')
          expect(email.html_part.body).to include('<i>Third approved artwork</i><span>, 1997</span>')
        end
      end
    end
  end
end
