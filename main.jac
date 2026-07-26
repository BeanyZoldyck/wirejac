"""WireJac headless hardware service entry point."""

include hardware.api;
import hardware.integration as integration;


with entry {
    integration._register_hardware_service();
}
