"""Prints the tail of the Minecraft VM's serial console (boot + first-boot setup log)."""
import os, re, time, oci

key_path = os.path.expanduser("~/oci_key.pem")
open(key_path, "w").write(os.environ["OCI_KEY"].strip() + "\n"); os.chmod(key_path, 0o600)
config = {"user": os.environ["OCI_USER"].strip(), "tenancy": os.environ["OCI_TENANCY"].strip(),
          "fingerprint": os.environ["OCI_FINGERPRINT"].strip(), "key_file": key_path,
          "region": "sa-santiago-1"}
compute = oci.core.ComputeClient(config)
tenancy = config["tenancy"]
inst = next(i for i in compute.list_instances(tenancy).data
            if i.shape == "VM.Standard.A1.Flex" and i.lifecycle_state not in ("TERMINATED", "TERMINATING"))
print("instance", inst.display_name, inst.lifecycle_state, inst.time_created)
h = compute.capture_console_history(oci.core.models.CaptureConsoleHistoryDetails(instance_id=inst.id)).data
for _ in range(30):
    h = compute.get_console_history(h.id).data
    if h.lifecycle_state == "SUCCEEDED": break
    time.sleep(5)
text = compute.get_console_history_content(h.id, length=10_000_000).data
text = text if isinstance(text, str) else text.decode("utf-8", "replace")
lines = [l for l in text.splitlines() if not re.search(r"rcon|password|PASS", l, re.I)]
keep = [l for l in lines if re.search(r"cloud-init|mc-setup|\+ |error|fail|SETUP|Chosen|download|skipping|E: |Traceback", l, re.I)]
print("\n".join(keep[-250:]))
print("----- raw tail -----")
print("\n".join(lines[-80:]))
compute.delete_console_history(h.id)
