// Smoke test for the SwiftShader Vulkan HAL (vulkan.swiftshader.so), run inside Google's userspace (bionic) under QEMU:
// opens it the way Android's Vulkan loader does (HAL_MODULE_INFO_SYM "HMI" -> methods->open("vk0")), creates an instance and a
// device on the CPU "GPU", checks the extensions HWUI/ANGLE/SurfaceFlinger need, and runs a queue submission (fill + readback).
// With a SPIR-V compute shader (argv[2], optional) it also runs a pipeline, which exercises SwiftShader's JIT.
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <hardware/hwvulkan.h>
#include <vulkan/vulkan.h>

#define CHECK(x) do { VkResult r_ = (x); if (r_ != VK_SUCCESS) { printf("VKTEST_FAIL %s = %d (line %d)\n", #x, r_, __LINE__); return 1; } } while (0)
#define NEED(cond, msg) do { if (!(cond)) { printf("VKTEST_FAIL %s (line %d)\n", msg, __LINE__); return 1; } } while (0)

static PFN_vkGetInstanceProcAddr gipa;
static PFN_vkGetDeviceProcAddr gdpa;
#define IFN(inst, n) PFN_##n n = (PFN_##n)gipa(inst, #n); NEED(n, "missing " #n)
#define DFN(dev, n) PFN_##n n = (PFN_##n)gdpa(dev, #n); NEED(n, "missing " #n)

static int has_ext(VkExtensionProperties *p, uint32_t n, const char *name) {
  for (uint32_t i = 0; i < n; i++) if (!strcmp(p[i].extensionName, name)) return 1;
  return 0;
}

int main(int argc, char **argv) {
  const char *path = argc > 1 ? argv[1] : "/vendor/lib64/hw/vulkan.intel.so";
  void *h = dlopen(path, RTLD_NOW | RTLD_LOCAL);
  NEED(h, dlerror());
  hwvulkan_module_t *m = (hwvulkan_module_t *)dlsym(h, HAL_MODULE_INFO_SYM_AS_STR);
  NEED(m, "no HMI symbol");
  printf("HAL: tag=%.4s id=%s name=%s author=%s api=0x%x\n", (char *)&m->common.tag, m->common.id, m->common.name, m->common.author,
         m->common.module_api_version);
  NEED(m->common.tag == HARDWARE_MODULE_TAG, "bad tag");
  NEED(!strcmp(m->common.id, HWVULKAN_HARDWARE_MODULE_ID), "module id is not \"vulkan\"");
  hw_device_t *hd = NULL;
  NEED(m->common.methods->open(&m->common, HWVULKAN_DEVICE_0, &hd) == 0 && hd, "open vk0");
  hwvulkan_device_t *dev0 = (hwvulkan_device_t *)hd;
  NEED(hd->version == HWVULKAN_DEVICE_API_VERSION_0_1, "device version");

  uint32_t n = 0;
  CHECK(dev0->EnumerateInstanceExtensionProperties(NULL, &n, NULL));
  printf("instance extensions: %u\n", n);
  VkApplicationInfo ai = {VK_STRUCTURE_TYPE_APPLICATION_INFO, NULL, "vktest", 1, "vktest", 1, VK_API_VERSION_1_1};
  VkInstanceCreateInfo ici = {VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, NULL, 0, &ai, 0, NULL, 0, NULL};
  VkInstance inst;
  CHECK(dev0->CreateInstance(&ici, NULL, &inst));
  gipa = dev0->GetInstanceProcAddr;
  IFN(inst, vkEnumeratePhysicalDevices); IFN(inst, vkGetPhysicalDeviceProperties); IFN(inst, vkGetPhysicalDeviceQueueFamilyProperties);
  IFN(inst, vkGetPhysicalDeviceMemoryProperties); IFN(inst, vkEnumerateDeviceExtensionProperties); IFN(inst, vkCreateDevice);
  IFN(inst, vkGetDeviceProcAddr);
  gdpa = vkGetDeviceProcAddr;

  uint32_t np = 0;
  CHECK(vkEnumeratePhysicalDevices(inst, &np, NULL));
  NEED(np == 1, "expected exactly one physical device");
  VkPhysicalDevice pd; np = 1;
  CHECK(vkEnumeratePhysicalDevices(inst, &np, &pd));
  VkPhysicalDeviceProperties pr; vkGetPhysicalDeviceProperties(pd, &pr);
  printf("device: %s type=%d vendor=0x%x api=%u.%u.%u\n", pr.deviceName, pr.deviceType, pr.vendorID, VK_VERSION_MAJOR(pr.apiVersion),
         VK_VERSION_MINOR(pr.apiVersion), VK_VERSION_PATCH(pr.apiVersion));
  NEED(pr.deviceType == VK_PHYSICAL_DEVICE_TYPE_CPU, "not a CPU device");
  NEED(pr.apiVersion >= VK_API_VERSION_1_1, "Vulkan < 1.1");

  uint32_t ne = 0;
  CHECK(vkEnumerateDeviceExtensionProperties(pd, NULL, &ne, NULL));
  VkExtensionProperties *ep = calloc(ne, sizeof *ep);
  CHECK(vkEnumerateDeviceExtensionProperties(pd, NULL, &ne, ep));
  static const char *want[] = {"VK_ANDROID_native_buffer", "VK_ANDROID_external_memory_android_hardware_buffer", "VK_KHR_external_memory_fd",
                               "VK_KHR_external_semaphore_fd", "VK_EXT_queue_family_foreign", "VK_KHR_sampler_ycbcr_conversion",
                               "VK_KHR_maintenance1", "VK_KHR_dedicated_allocation", "VK_KHR_get_memory_requirements2"};
  int missing = 0;
  for (unsigned i = 0; i < sizeof want / sizeof *want; i++) { int h_ = has_ext(ep, ne, want[i]); printf("  %-52s %s\n", want[i], h_ ? "yes" : "NO"); missing += !h_; }
  printf("device extensions: %u (%d wanted missing)\n", ne, missing);

  uint32_t nq = 0;
  vkGetPhysicalDeviceQueueFamilyProperties(pd, &nq, NULL);
  VkQueueFamilyProperties *qf = calloc(nq, sizeof *qf);
  vkGetPhysicalDeviceQueueFamilyProperties(pd, &nq, qf);
  NEED(nq >= 1 && (qf[0].queueFlags & VK_QUEUE_GRAPHICS_BIT) && (qf[0].queueFlags & VK_QUEUE_COMPUTE_BIT), "queue family 0 not graphics+compute");
  float prio = 1.f;
  VkDeviceQueueCreateInfo qci = {VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, NULL, 0, 0, 1, &prio};
  VkDeviceCreateInfo dci = {VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, NULL, 0, 1, &qci, 0, NULL, 0, NULL, NULL};
  VkDevice dev;
  CHECK(vkCreateDevice(pd, &dci, NULL, &dev));
  gdpa = (PFN_vkGetDeviceProcAddr)vkGetDeviceProcAddr(dev, "vkGetDeviceProcAddr");
  NEED(gdpa, "no vkGetDeviceProcAddr on device");
  DFN(dev, vkGetDeviceQueue); DFN(dev, vkCreateBuffer); DFN(dev, vkGetBufferMemoryRequirements); DFN(dev, vkAllocateMemory);
  DFN(dev, vkBindBufferMemory); DFN(dev, vkMapMemory); DFN(dev, vkCreateCommandPool); DFN(dev, vkAllocateCommandBuffers);
  DFN(dev, vkBeginCommandBuffer); DFN(dev, vkCmdFillBuffer); DFN(dev, vkEndCommandBuffer); DFN(dev, vkQueueSubmit);
  DFN(dev, vkQueueWaitIdle);
  VkPhysicalDeviceMemoryProperties mp;
  vkGetPhysicalDeviceMemoryProperties(pd, &mp);

  VkQueue q; vkGetDeviceQueue(dev, 0, 0, &q);
  VkBufferCreateInfo bci = {VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, NULL, 0, 4096, VK_BUFFER_USAGE_TRANSFER_DST_BIT | VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
                            VK_SHARING_MODE_EXCLUSIVE, 0, NULL};
  VkBuffer buf; CHECK(vkCreateBuffer(dev, &bci, NULL, &buf));
  VkMemoryRequirements mr; vkGetBufferMemoryRequirements(dev, buf, &mr);
  uint32_t mt = ~0u;
  for (uint32_t i = 0; i < mp.memoryTypeCount; i++)
    if ((mr.memoryTypeBits & (1u << i)) && (mp.memoryTypes[i].propertyFlags & VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT)) { mt = i; break; }
  NEED(mt != ~0u, "no host visible memory");
  VkMemoryAllocateInfo mai = {VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, NULL, mr.size, mt};
  VkDeviceMemory mem; CHECK(vkAllocateMemory(dev, &mai, NULL, &mem));
  CHECK(vkBindBufferMemory(dev, buf, mem, 0));
  VkCommandPoolCreateInfo cpi = {VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO, NULL, 0, 0};
  VkCommandPool pool; CHECK(vkCreateCommandPool(dev, &cpi, NULL, &pool));
  VkCommandBufferAllocateInfo cbi = {VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, NULL, pool, VK_COMMAND_BUFFER_LEVEL_PRIMARY, 1};
  VkCommandBuffer cb; CHECK(vkAllocateCommandBuffers(dev, &cbi, &cb));
  VkCommandBufferBeginInfo bi = {VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO, NULL, 0, NULL};
  CHECK(vkBeginCommandBuffer(cb, &bi));
  vkCmdFillBuffer(cb, buf, 0, 4096, 0xC0FFEE42u);
  CHECK(vkEndCommandBuffer(cb));
  VkSubmitInfo si = {VK_STRUCTURE_TYPE_SUBMIT_INFO, NULL, 0, NULL, NULL, 1, &cb, 0, NULL};
  CHECK(vkQueueSubmit(q, 1, &si, VK_NULL_HANDLE));
  CHECK(vkQueueWaitIdle(q));
  uint32_t *p; CHECK(vkMapMemory(dev, mem, 0, 4096, 0, (void **)&p));
  for (int i = 0; i < 1024; i++) NEED(p[i] == 0xC0FFEE42u, "fill readback mismatch");
  printf("queue submit: vkCmdFillBuffer readback ok\n");

  if (argc > 2) {  // compute: SPIR-V from file; main writes 7*gl_GlobalInvocationID.x+1 to storage buffer binding 0
    DFN(dev, vkCreateShaderModule); DFN(dev, vkCreateDescriptorSetLayout); DFN(dev, vkCreatePipelineLayout); DFN(dev, vkCreateComputePipelines);
    DFN(dev, vkCreateDescriptorPool); DFN(dev, vkAllocateDescriptorSets); DFN(dev, vkUpdateDescriptorSets); DFN(dev, vkCmdBindPipeline);
    DFN(dev, vkCmdBindDescriptorSets); DFN(dev, vkCmdDispatch); DFN(dev, vkResetCommandBuffer);
    FILE *f = fopen(argv[2], "rb"); NEED(f, "open spv"); fseek(f, 0, SEEK_END); long sz = ftell(f); fseek(f, 0, SEEK_SET);
    uint32_t *code = malloc(sz); NEED(fread(code, 1, sz, f) == (size_t)sz, "read spv"); fclose(f);
    VkShaderModuleCreateInfo smi = {VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO, NULL, 0, (size_t)sz, code};
    VkShaderModule sm; CHECK(vkCreateShaderModule(dev, &smi, NULL, &sm));
    VkDescriptorSetLayoutBinding b = {0, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1, VK_SHADER_STAGE_COMPUTE_BIT, NULL};
    VkDescriptorSetLayoutCreateInfo dsl = {VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO, NULL, 0, 1, &b};
    VkDescriptorSetLayout sl; CHECK(vkCreateDescriptorSetLayout(dev, &dsl, NULL, &sl));
    VkPipelineLayoutCreateInfo pli = {VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO, NULL, 0, 1, &sl, 0, NULL};
    VkPipelineLayout pl; CHECK(vkCreatePipelineLayout(dev, &pli, NULL, &pl));
    VkComputePipelineCreateInfo cpci = {VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO, NULL, 0,
        {VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, NULL, 0, VK_SHADER_STAGE_COMPUTE_BIT, sm, "main", NULL}, pl, VK_NULL_HANDLE, 0};
    VkPipeline pipe; CHECK(vkCreateComputePipelines(dev, VK_NULL_HANDLE, 1, &cpci, NULL, &pipe));
    VkDescriptorPoolSize ps = {VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1};
    VkDescriptorPoolCreateInfo dpi = {VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO, NULL, 0, 1, 1, &ps};
    VkDescriptorPool dp; CHECK(vkCreateDescriptorPool(dev, &dpi, NULL, &dp));
    VkDescriptorSetAllocateInfo dai = {VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO, NULL, dp, 1, &sl};
    VkDescriptorSet ds; CHECK(vkAllocateDescriptorSets(dev, &dai, &ds));
    VkDescriptorBufferInfo dbi = {buf, 0, 4096};
    VkWriteDescriptorSet w = {VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, NULL, ds, 0, 0, 1, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, NULL, &dbi, NULL};
    vkUpdateDescriptorSets(dev, 1, &w, 0, NULL);
    CHECK(vkResetCommandBuffer(cb, 0));
    CHECK(vkBeginCommandBuffer(cb, &bi));
    vkCmdBindPipeline(cb, VK_PIPELINE_BIND_POINT_COMPUTE, pipe);
    vkCmdBindDescriptorSets(cb, VK_PIPELINE_BIND_POINT_COMPUTE, pl, 0, 1, &ds, 0, NULL);
    vkCmdDispatch(cb, 16, 1, 1);  // 16 groups of 64
    CHECK(vkEndCommandBuffer(cb));
    CHECK(vkQueueSubmit(q, 1, &si, VK_NULL_HANDLE));
    CHECK(vkQueueWaitIdle(q));
    for (uint32_t i = 0; i < 1024; i++) if (p[i] != 7 * i + 1) { printf("VKTEST_FAIL compute result[%u]=%u\n", i, p[i]); return 1; }
    printf("compute pipeline (JIT) readback ok\n");
  }
  printf("VKTEST_PASS\n");
  return 0;
}
