# Jump host (management VNet) and test client (client VNet), both off by default in the lab. No public IPs: both
# are reached through the hub Bastion (`az network bastion ssh --auth-type AAD`, enable primary_bastion_enabled
# first), sign-in with Entra ID (AADSSHLoginForLinux).
# The generated SSH key is only the provisioning credential and is never used by people.
resource "tls_private_key" "vm" {
  algorithm = "ED25519"
}

locals {
  jump_cloud_init = <<-CLOUDINIT
    #cloud-config
    package_update: true
    packages: [jq, unzip, git]
    runcmd:
      - curl -sL https://aka.ms/InstallAzureCLIDeb | bash
      - az aks install-cli
  CLOUDINIT
}

resource "azurerm_network_interface" "jump" {
  count               = var.jump_host_enabled ? 1 : 0
  name                = "nic-vm-mgmt-jump-01"
  location            = var.location
  resource_group_name = azurerm_resource_group.management_network.name
  tags                = var.tags

  ip_configuration {
    name                          = "ipconfig1"
    subnet_id                     = azurerm_subnet.management_jump.id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "azurerm_linux_virtual_machine" "jump" {
  count                           = var.jump_host_enabled ? 1 : 0
  name                            = "vm-mgmt-jump-01"
  location                        = var.location
  resource_group_name             = azurerm_resource_group.management_network.name
  size                            = var.jump_host_vm_size
  zone                            = "1"
  admin_username                  = "azureuser"
  disable_password_authentication = true
  encryption_at_host_enabled      = true
  network_interface_ids           = [azurerm_network_interface.jump[0].id]
  custom_data                     = base64encode(local.jump_cloud_init)
  secure_boot_enabled             = true
  vtpm_enabled                    = true
  tags                            = var.tags

  admin_ssh_key {
    username   = "azureuser"
    public_key = tls_private_key.vm.public_key_openssh
  }

  identity {
    type = "SystemAssigned"
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }
}

resource "azurerm_virtual_machine_extension" "jump_entra_login" {
  count                      = var.jump_host_enabled ? 1 : 0
  name                       = "AADSSHLoginForLinux"
  virtual_machine_id         = azurerm_linux_virtual_machine.jump[0].id
  publisher                  = "Microsoft.Azure.ActiveDirectory"
  type                       = "AADSSHLoginForLinux"
  type_handler_version       = "1.0"
  auto_upgrade_minor_version = true
}

resource "azurerm_role_assignment" "jump_admin_login" {
  count                = var.jump_host_enabled && var.admin_group_object_id != "" ? 1 : 0
  scope                = azurerm_linux_virtual_machine.jump[0].id
  role_definition_name = "Virtual Machine Administrator Login"
  principal_id         = var.admin_group_object_id
}

resource "azurerm_network_interface" "client" {
  provider            = azurerm.connectivity
  count               = var.client_vm_enabled ? 1 : 0
  name                = "nic-vm-client-01"
  location            = var.location
  resource_group_name = azurerm_resource_group.client.name
  tags                = var.tags

  ip_configuration {
    name                          = "ipconfig1"
    subnet_id                     = azurerm_subnet.client["snet_clients"].id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "azurerm_linux_virtual_machine" "client" {
  provider                        = azurerm.connectivity
  count                           = var.client_vm_enabled ? 1 : 0
  name                            = "vm-client-01"
  location                        = var.location
  resource_group_name             = azurerm_resource_group.client.name
  size                            = var.client_vm_size
  zone                            = "1"
  admin_username                  = "azureuser"
  disable_password_authentication = true
  encryption_at_host_enabled      = true
  network_interface_ids           = [azurerm_network_interface.client[0].id]
  secure_boot_enabled             = true
  vtpm_enabled                    = true
  custom_data = base64encode(<<-CLOUDINIT
    #cloud-config
    package_update: true
    packages: [curl, jq, dnsutils, hey]
  CLOUDINIT
  )
  tags = var.tags

  admin_ssh_key {
    username   = "azureuser"
    public_key = tls_private_key.vm.public_key_openssh
  }

  identity {
    type = "SystemAssigned"
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }
}

resource "azurerm_virtual_machine_extension" "client_entra_login" {
  provider                   = azurerm.connectivity
  count                      = var.client_vm_enabled ? 1 : 0
  name                       = "AADSSHLoginForLinux"
  virtual_machine_id         = azurerm_linux_virtual_machine.client[0].id
  publisher                  = "Microsoft.Azure.ActiveDirectory"
  type                       = "AADSSHLoginForLinux"
  type_handler_version       = "1.0"
  auto_upgrade_minor_version = true
}

resource "azurerm_role_assignment" "client_admin_login" {
  provider             = azurerm.connectivity
  count                = var.client_vm_enabled && var.admin_group_object_id != "" ? 1 : 0
  scope                = azurerm_linux_virtual_machine.client[0].id
  role_definition_name = "Virtual Machine Administrator Login"
  principal_id         = var.admin_group_object_id
}

# Earlier addresses of the Entra ID login extensions. Azure refuses to delete an extension of a stopped VM (409
# OperationNotAllowed), so Terraform forgets them instead: they are deleted together with their VM.
removed {
  from = azurerm_virtual_machine_extension.jump_aad_login
  lifecycle {
    destroy = false
  }
}

removed {
  from = azurerm_virtual_machine_extension.client_aad_login
  lifecycle {
    destroy = false
  }
}
