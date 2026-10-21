"""Keeps asking Oracle Cloud for an Always Free Ampere A1 instance until it gets one.

Safety: only ever creates ONE VM.Standard.A1.Flex with 2 OCPU / 12 GB / 100 GB disk,
which is inside the Always Free allowance. If any A1 instance already exists, it does nothing.
"""
import base64, os, sys, time, datetime
import oci

REGION = os.environ.get("OCI_REGION", "sa-santiago-1")
SHAPE = "VM.Standard.A1.Flex"
OCPUS, MEMORY_GB, BOOT_GB = 2, 12, 100
VCN_NAME = os.environ.get("VCN_NAME", "Servermc")
INSTANCE_NAME = "minecraft"
RUN_SECONDS = int(os.environ.get("RUN_SECONDS", "780"))   # keep trying this long per workflow run
WAIT_SECONDS = int(os.environ.get("WAIT_SECONDS", "60"))  # pause between attempts

key_path = os.path.expanduser("~/oci_key.pem")
with open(key_path, "w") as f:
    f.write(os.environ["OCI_KEY"].strip() + "\n")
os.chmod(key_path, 0o600)
config = {
    "user": os.environ["OCI_USER"].strip(),
    "tenancy": os.environ["OCI_TENANCY"].strip(),
    "fingerprint": os.environ["OCI_FINGERPRINT"].strip(),
    "key_file": key_path,
    "region": REGION,
}
oci.config.validate_config(config)
tenancy = config["tenancy"]
compute = oci.core.ComputeClient(config)
network = oci.core.VirtualNetworkClient(config)
identity = oci.identity.IdentityClient(config)

def log(*a):
    print(datetime.datetime.utcnow().strftime("%H:%M:%S"), *a, flush=True)

def summary(text):
    p = os.environ.get("GITHUB_STEP_SUMMARY")
    if p:
        with open(p, "a") as f:
            f.write(text + "\n")

def existing_a1():
    for inst in oci.pagination.list_call_get_all_results(compute.list_instances, tenancy).data:
        if inst.shape == SHAPE and inst.lifecycle_state not in ("TERMINATED", "TERMINATING"):
            return inst
    return None

def public_ip(inst):
    for att in compute.list_vnic_attachments(tenancy, instance_id=inst.id).data:
        if att.lifecycle_state == "ATTACHED":
            return network.get_vnic(att.vnic_id).data.public_ip
    return None

def report_done(inst):
    ip = None
    for _ in range(30):
        ip = public_ip(inst)
        if ip: break
        time.sleep(10)
    msg = f"SERVER_CREATED name={inst.display_name} state={inst.lifecycle_state} ip={ip}"
    log(msg)
    summary(f"## Server exists\n\nPublic IP: `{ip}`\n\nState: {inst.lifecycle_state}")
    with open(os.environ.get("GITHUB_OUTPUT", "/dev/null"), "a") as f:
        f.write(f"created=true\nip={ip}\n")

inst = existing_a1()
if inst:
    log("An A1 instance already exists, nothing to do.")
    report_done(inst)
    sys.exit(0)

# Subnet: the public subnet of the VCN called Servermc
vcn = next(v for v in network.list_vcns(tenancy).data if v.display_name == VCN_NAME)
subnet = next(s for s in network.list_subnets(tenancy, vcn_id=vcn.id).data
              if not s.prohibit_public_ip_on_vnic)

# Newest Canonical Ubuntu 24.04 image that runs on Ampere A1 (not the Minimal variant)
images = compute.list_images(tenancy, operating_system="Canonical Ubuntu",
                             operating_system_version="24.04", shape=SHAPE,
                             sort_by="TIMECREATED", sort_order="DESC").data
images = [i for i in images if "Minimal" not in i.display_name] or images
image = images[0]
ads = [a.name for a in identity.list_availability_domains(tenancy).data]
log("VCN", vcn.display_name, "| subnet", subnet.display_name, "| image", image.display_name, "| ADs", ads)

here = os.path.dirname(os.path.abspath(__file__))
user_data = base64.b64encode(open(os.path.join(here, "server", "setup.sh"), "rb").read()).decode()
ssh_key = open(os.path.join(here, "server", "ssh_public_key.pub")).read().strip()

def details(ad):
    return oci.core.models.LaunchInstanceDetails(
        availability_domain=ad,
        compartment_id=tenancy,
        display_name=INSTANCE_NAME,
        shape=SHAPE,
        shape_config=oci.core.models.LaunchInstanceShapeConfigDetails(ocpus=OCPUS, memory_in_gbs=MEMORY_GB),
        source_details=oci.core.models.InstanceSourceViaImageDetails(
            image_id=image.id, boot_volume_size_in_gbs=BOOT_GB),
        create_vnic_details=oci.core.models.CreateVnicDetails(
            subnet_id=subnet.id, assign_public_ip=True, display_name="minecraft-vnic"),
        metadata={"ssh_authorized_keys": ssh_key, "user_data": user_data},
    )

deadline = time.time() + RUN_SECONDS
attempt = 0
while True:
    for ad in ads:
        attempt += 1
        try:
            inst = compute.launch_instance(details(ad)).data
            log(f"attempt {attempt}: SUCCESS in {ad}!")
            inst = oci.wait_until(compute, compute.get_instance(inst.id), "lifecycle_state",
                                  "RUNNING", max_wait_seconds=600).data
            report_done(inst)
            sys.exit(0)
        except oci.exceptions.ServiceError as e:
            if e.status == 500 or "capacity" in (e.message or "").lower():
                log(f"attempt {attempt}: out of capacity in {ad}")
            elif e.status == 429:
                log(f"attempt {attempt}: rate limited, backing off")
                time.sleep(WAIT_SECONDS)
            else:
                log(f"attempt {attempt}: UNEXPECTED {e.status} {e.code}: {e.message}")
                summary(f"## Unexpected error\n\n`{e.status} {e.code}: {e.message}`")
                sys.exit(1)
    if time.time() + WAIT_SECONDS > deadline:
        log("No capacity this run; the next scheduled run will keep trying.")
        summary(f"No capacity yet ({attempt} attempts this run). Still trying.")
        sys.exit(0)
    time.sleep(WAIT_SECONDS)
