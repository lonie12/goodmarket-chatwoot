<script>
import TeamAvailability from 'widget/components/TeamAvailability.vue';
import { mapGetters } from 'vuex';
import { useRouter } from 'vue-router';
import configMixin from 'widget/mixins/configMixin';
import ArticleContainer from '../components/pageComponents/Home/Article/ArticleContainer.vue';
export default {
  name: 'Home',
  components: {
    ArticleContainer,
    TeamAvailability,
  },
  mixins: [configMixin],
  setup() {
    const router = useRouter();
    return { router };
  },
  computed: {
    ...mapGetters({
      availableAgents: 'agent/availableAgents',
      conversationSize: 'conversation/getConversationSize',
      unreadMessageCount: 'conversation/getUnreadMessageCount',
    }),
  },
  // Goodmarket: skip the "Start Conversation" landing card entirely — go
  // straight where tapping it would (same guard: pre-chat form only when
  // there is no conversation yet, otherwise straight to messages). Upstream
  // Chatwoot has no setting for this (chatwoot/chatwoot#5962, #11228, both
  // still open), so this is the smallest patch that gets it: one hook,
  // reusing the exact method the button already called.
  //
  // Trade-off, on purpose: the "back" button from Messages/PreChatForm
  // returns here, which now immediately forwards again — a visitor cannot
  // "go back" to this screen anymore. Accepted rather than adding state to
  // tell an initial mount apart from an explicit back-navigation for a
  // screen we deliberately no longer want shown either way.
  mounted() {
    this.startConversation();
  },
  methods: {
    startConversation() {
      if (this.preChatFormEnabled && !this.conversationSize) {
        return this.router.replace({ name: 'prechat-form' });
      }
      return this.router.replace({ name: 'messages' });
    },
  },
};
</script>

<template>
  <div class="z-50 flex flex-col justify-end flex-1 w-full p-4 gap-4">
    <TeamAvailability
      :available-agents="availableAgents"
      :has-conversation="!!conversationSize"
      :unread-count="unreadMessageCount"
      @start-conversation="startConversation"
    />

    <ArticleContainer />
  </div>
</template>
