class Mnemodyne::EraseVaultsJob < ApplicationJob

  def perform
    Mnemodyne::Vault.where("erase_after <= ?", Time.current).find_each do |vault|
      Mnemodyne::Erasure.perform(vault)
    rescue Mnemodyne::Erasure::Invalid
      # Fail closed on a changed graph; no graph payload goes to the job log.
      Rails.logger.warn("Mnemodyne erasure held: graph changed after export acknowledgement")
    end
  end

end
