# TODO: logic is written tailored to contact import since its the only import available
# let's break this logic and clean this up in future

class DataImportJob < ApplicationJob
  queue_as :low

  def perform(data_import)
    contacts = []
    rejected_contacts = []
    @data_import = data_import
    @data_import.update!(status: :processing)
    csv = CSV.parse(@data_import.import_file.download, headers: true)
    csv.each { |row| contacts << build_contact(row.to_h.with_indifferent_access, @data_import.account) }
    contacts.each_slice(1000) do |contact_chunks|
      rejected_contacts << contact_chunks.reject { |contact| contact.valid? && contact.save! }
    end
    rejected_contacts = rejected_contacts.flatten
    @data_import.update!(status: :completed, processed_records: (csv.length - rejected_contacts.length), total_records: csv.length)
    save_invalid_records_csv(rejected_contacts)
  end

  private

  def build_contact(params, account)
    # TODO: rather than doing the find or initialize individually lets fetch objects in bulk and update them in memory
    contact = init_contact(params, account)

    contact.name = params[:name] if params[:name].present?
    contact.assign_attributes(custom_attributes: contact.custom_attributes.merge(params.except(:identifier, :email, :name, :phone_number)))
    contact
  end

  # add the phone number check here
  def get_identified_contacts(params, account)
    identifier_contact = account.contacts.find_by(identifier: params[:identifier]) if params[:identifier]
    email_contact = account.contacts.find_by(email: params[:email]) if params[:email]
    [identifier_contact, email_contact]
  end

  def save_invalid_records_csv(rejected_contacts)
    return if rejected_contacts.blank?

    csv_data = CSV.generate do |csv|
      csv << %w[id first_name last_name email phone_number identifier gender errors]
      rejected_contacts.each do |record|
        csv << [
          record['id'],
          record.custom_attributes['first_name'],
          record.custom_attributes['last_name'],
          record['email'],
          record['phone_number'],
          record['identifier'],
          record.custom_attributes['gender'],
          record.errors.full_messages.join(',')
        ]
      end
    end

    send_erroneous_records_to_admin(csv_data)
  end

  def send_erroneous_records_to_admin(csv_data)
    @data_import.erroneous_import_file.attach(io: StringIO.new(csv_data), filename: "#{Time.zone.today.strftime('%Y%m%d')}_contacts.csv",
                                              content_type: 'text/csv')
    AdministratorNotifications::ChannelNotificationsMailer.with(account: @data_import.account).erroneous_import_records(@data_import).deliver_later
  end

  def init_contact(params, account)
    identifier_contact, email_contact = get_identified_contacts(params, account)

    # intiating the new contact / contact attributes only by ensuring the identifier or email duplication errors won't occur
    contact = identifier_contact
    contact&.email = params[:email] if params[:email].present? && email_contact.blank?
    contact ||= email_contact
    contact ||= account.contacts.new(params.slice(:email, :identifier, :phone_number))
    contact
  end
end
